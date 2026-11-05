%% @doc Serial, selectable Rust NIF validation with structured results.
%% run/0 selects smoke; run(stress) is explicit and bounded. Erlang isolation
%% catches recoverable errors. A native abort can still stop BEAM, and killing
%% a process cannot cancel a dirty NIF. After a case timeout, remaining cases skip.
-module(grisp_rust_testsuite).
-export([run/0, run/1, run_case/2, categories/0, cases/0, cases/1, await/2, await_native/2]).

%% Category order is also execution/report order; stress stays explicitly selectable.
modules() ->
    [{core, grisp_rust_test_core}, {threading, grisp_rust_test_threading},
     {io, grisp_rust_test_io}, {rustler, grisp_rust_test_rustler},
     {async, grisp_rust_test_async}, {scheduling, grisp_rust_test_scheduling},
     {stress, grisp_rust_test_stress}].

%% @doc List valid category selectors in report order.
categories() -> [Category || {Category, _} <- modules()].
%% @doc Describe all checks, including opt-in stress; does not execute native code.
cases() -> lists:flatmap(fun cases/1, categories()).
%% @doc Expand {Name, Title, OutputKind} declarations into runner descriptors.
%% OutputKind marks quiet, console, or expected panic text for the report.
cases(Category) ->
    case lists:keyfind(Category, 1, modules()) of
        {Category, Module} ->
            [#{category => Category, name => Name, title => Title, output => Output}
             || {Name, Title, Output} <- Module:cases()];
        false -> error({unknown_category, Category})
    end.

%% @doc Run the default smoke profile and return counts plus per-case results.
run() -> run(#{}).
%% @doc Select a profile/category/list, or pass options for selection and bounds.
%% Runs are serial per node; uncertain native completion requires a VM restart.
run(smoke) -> run(#{profile => smoke});
run(stress) -> run(#{profile => stress});
run(all) -> run(#{profile => all});
run(Category) when is_atom(Category) -> run(#{categories => [Category]});
run(Categories) when is_list(Categories) -> run(#{categories => Categories});
run(Options) when is_map(Options) ->
    Settings = maps:merge(#{profile => smoke, scratch_root => "/tmp", timeout_ms => 10000,
                            stress_iterations => 5000, report => true}, Options),
    true = is_integer(maps:get(timeout_ms, Settings)) andalso maps:get(timeout_ms, Settings) > 0,
    Iterations = maps:get(stress_iterations, Settings),
    true = is_integer(Iterations) andalso Iterations > 0 andalso Iterations =< 10000,
    Plan = plan(Settings),
    Lock = {?MODULE, self()},
    case global:set_lock(Lock, [node()], 0) of
        false -> {error, already_running};
        true ->
            try
                case persistent_term:get({?MODULE, state}, undefined) of
                    undefined ->
                        %% An interrupted runner can leave native work behind.
                        %% Keep this marker unless the whole run completes.
                        persistent_term:put({?MODULE, state}, {running, self()}),
                        Report = run_plan(Plan, Settings),
                        case maps:get(timeout, Report) of
                            0 -> persistent_term:erase({?MODULE, state});
                            _ -> ok
                        end,
                        Report;
                    {timeout, Previous} -> {error, {previous_case_timeout, Previous}};
                    {running, Owner} -> {error, {previous_run_interrupted, Owner}}
                end
            after global:del_lock(Lock, [node()]) end
    end.

%% @doc Run one named check using the same isolation and cleanup rules as a full run.
run_case(Category, Name) -> run(#{categories => [Category], cases => [Name]}).

%% Validate selectors before taking the run lock or invoking any NIF.
plan(Options) ->
    Default = case maps:get(profile, Options) of
        smoke -> categories() -- [stress];
        stress -> [stress];
        all -> categories();
        Other -> error({unknown_profile, Other})
    end,
    Categories = maps:get(categories, Options, Default),
    true = is_list(Categories),
    true = length(Categories) == length(lists:usort(Categories)),
    Available = lists:flatmap(fun cases/1, Categories),
    case maps:find(cases, Options) of
        error -> Available;
        {ok, Names} ->
            Missing = Names -- [maps:get(name, Case) || Case <- Available],
            case Missing of [] -> ok; _ -> error({unknown_cases, Missing}) end,
            [Case || Case <- Available, lists:member(maps:get(name, Case), Names)]
    end.

%% Keep machine-readable results independent of the optional console report.
run_plan(Plan, Options) ->
    Started = erlang:monotonic_time(millisecond),
    print_header(Plan, Options),
    Results = run_cases(Plan, Options, undefined, []),
    Summary = counts(Results),
    Report = Summary#{elapsed_ms => erlang:monotonic_time(millisecond) - Started,
                      profile => maps:get(profile, Options), results => Results},
    print_summary(Report, Options),
    Report.

print_header(_Plan, #{report := false}) -> ok;
print_header(Plan, Options) ->
    #{rust := Rust, libc := Libc, inventory := Inventory, rustler := Rustler} =
        grisp_rust_testsuite_nifs:build_versions(),
    say(Options, "~n============================================================~n"
        " GRiSP Rust NIF testsuite | profile: ~p | cases: ~B~n"
        " OTP ~s | schedulers: ~B | dirty CPU: ~B | dirty IO: ~B~n"
        " Rust ~s~n"
        " libc ~s | inventory ~s | Rustler ~s~n"
        "============================================================~n", [
            maps:get(profile, Options), length(Plan), erlang:system_info(otp_release),
            erlang:system_info(schedulers_online), erlang:system_info(dirty_cpu_schedulers_online),
            erlang:system_info(dirty_io_schedulers), Rust, Libc, Inventory, Rustler]).

%% Run serially so global native diagnostics belong to one check at a time.
%% After a timeout, retain the quarantine marker and describe the rest as skipped.
run_cases([], _Options, _Previous, Acc) -> lists:reverse(Acc);
run_cases([Case | Rest], Options, Previous, Acc) ->
    Category = maps:get(category, Case),
    case Category == Previous of
        true -> ok;
        false -> say(Options, "~n[~p]~n", [Category])
    end,
    Name = maps:get(name, Case),
    say(Options, "  ~-7s ~p/~p - ~s~n", ["RUN", Category, Name, maps:get(title, Case)]),
    case maps:get(output, Case) of
        quiet -> ok;
        console -> say(Options, "       --- expected native stdout/stderr follows ---~n", []);
        panic -> say(Options, "       --- deliberate panic output follows; recovery is required ---~n", [])
    end,
    {Category, Module} = lists:keyfind(Category, 1, modules()),
    Result = execute(Case, fun() -> Module:run(Name, Options) end, maps:get(timeout_ms, Options)),
    case maps:get(output, Case) of
        quiet -> ok;
        _ -> say(Options, "~n       --- end of expected native output ---~n", [])
    end,
    say(Options, "  ~-7s ~p/~p (~B ms)~n", [label(maps:get(status, Result)), Category,
        Name, maps:get(duration_ms, Result)]),
    case maps:get(detail, Result) of
        undefined -> ok;
        Detail -> say(Options, "          ~tp~n", [Detail])
    end,
    case maps:get(status, Result) of
        timeout ->
            persistent_term:put({?MODULE, state}, {timeout, maps:with([category, name], Case)}),
            say(Options, "  Native work may still be running; remaining cases are skipped.~n"
                "  Restart the VM before running the suite again.~n", []),
            Skipped = [C#{status => skipped, detail => previous_case_timeout, duration_ms => 0} || C <- Rest],
            lists:reverse([Result | Acc]) ++ Skipped;
        _ -> run_cases(Rest, Options, Category, [Result | Acc])
    end.

%% Bound the whole case, including owner teardown, in a monitored Erlang process.
%% Killing that process cannot cancel native work: timeout is not safe recovery.
execute(Case, Fun, Timeout) ->
    Started = erlang:monotonic_time(millisecond),
    Deadline = Started + Timeout,
    Parent = self(),
    Token = make_ref(),
    {Pid, Monitor} = spawn_monitor(fun() ->
        Result = try normalize(Fun())
        catch
            error:{native_cleanup_timeout, _} = Reason -> {timeout, Reason};
            error:{native_entry_timeout, _} = Reason -> {timeout, Reason};
            Class:Reason:Stack -> {failed, #{exception => {Class, Reason}, stack => lists:sublist(Stack, 4)}}
        end,
        Parent ! {Token, Result}
    end),
    {Status, Detail} = receive
        {Token, Value} ->
            %% A result precedes process teardown. Wait for DOWN so the next
            %% case does not overlap this process's heap/resource cleanup.
            receive
                {'DOWN', Monitor, process, Pid, normal} -> Value;
                {'DOWN', Monitor, process, Pid, Exit} -> {failed, {process_exit, Exit}}
            after max(0, Deadline - erlang:monotonic_time(millisecond)) ->
                exit(Pid, kill),
                erlang:demonitor(Monitor, [flush]),
                {timeout, {case_cleanup_timeout_ms, Timeout}}
            end;
        {'DOWN', Monitor, process, Pid, Reason} -> {failed, {process_exit, Reason}}
    after Timeout ->
        exit(Pid, kill),
        erlang:demonitor(Monitor, [flush]),
        {timeout, {case_timeout_ms, Timeout}}
    end,
    Case#{status => Status, detail => Detail,
          duration_ms => erlang:monotonic_time(millisecond) - Started}.

%% Category contract: ok/{ok,true}/{ok,Map}, {skip,Reason}, or {error,Reason}.
normalize(ok) -> {passed, undefined};
normalize({ok, true}) -> {passed, undefined};
normalize({ok, Detail}) when is_map(Detail) -> {passed, Detail};
normalize({skip, Reason}) -> {skipped, Reason};
normalize({error, Reason}) -> {failed, Reason};
normalize(Other) -> {failed, {unexpected_result, Other}}.

counts(Results) ->
    lists:foldl(fun(#{status := Status}, Acc) -> Acc#{Status := maps:get(Status, Acc) + 1} end,
        #{passed => 0, failed => 0, timeout => 0, skipped => 0}, Results).

%% Summarize all statuses; RTEMS-only host skips remain visible, not passes.
print_summary(#{results := Results} = Report, Options) ->
    say(Options, "~n------------------------------------------------------------~n"
        " Category       PASS  FAIL  TIMEOUT  SKIP~n", []),
    lists:foreach(fun(Category) ->
        Group = [R || R <- Results, maps:get(category, R) == Category],
        case Group of
            [] -> ok;
            _ ->
                C = counts(Group),
                say(Options, " ~-14s ~4B  ~4B  ~7B  ~4B~n", [atom_to_list(Category),
                    maps:get(passed, C), maps:get(failed, C), maps:get(timeout, C), maps:get(skipped, C)])
        end
    end, categories()),
    Outcome = case Report of
        #{failed := 0, timeout := 0, skipped := 0} -> "PASSED";
        #{failed := 0, timeout := 0, skipped := Skipped} when Skipped > 0 -> "PASSED WITH SKIPS";
        _ -> "FAILED"
    end,
    say(Options, "------------------------------------------------------------~n"
        " ~s~n"
        " Total: ~B passed, ~B failed, ~B timed out, ~B skipped (~B ms)~n"
        "============================================================~n", [
            Outcome, maps:get(passed, Report), maps:get(failed, Report), maps:get(timeout, Report),
            maps:get(skipped, Report), maps:get(elapsed_ms, Report)]).

%% Suppress only runner output; native stdout and panic hooks remain observable.
say(#{report := false}, _Format, _Args) -> ok;
say(_, Format, Args) -> io:format(Format, Args).
label(passed) -> "PASS";
label(failed) -> "FAIL";
label(timeout) -> "TIMEOUT";
label(skipped) -> "SKIP".

%% @doc Poll a cleanup condition with a monotonic bound; no unbounded native waits.
await(Condition, Timeout) -> await_until(Condition, erlang:monotonic_time(millisecond) + Timeout).

%% Unconfirmed native teardown must quarantine subsequent runs, like a case timeout.
await_native(Condition, Timeout) ->
    try await(Condition, Timeout)
    catch error:cleanup_timeout -> error({native_cleanup_timeout, Timeout}) end.

%% Retry the predicate against one deadline; callers must keep it short/nonblocking.
await_until(Condition, Deadline) ->
    case Condition() of
        true -> ok;
        false ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true -> timer:sleep(5), await_until(Condition, Deadline);
                false -> error(cleanup_timeout)
            end
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

failure_isolation_test() ->
    Case = #{category => test, name => fake},
    Failed = execute(Case, fun() -> error(expected_failure) end, 100),
    Passed = execute(Case, fun() -> ok end, 100),
    ?assertMatch(#{status := failed}, Failed),
    ?assertMatch(#{status := passed}, Passed),
    ?assertMatch(#{passed := 1, failed := 1}, counts([Failed, Passed])),
    ?assertMatch(#{status := timeout}, execute(Case, fun() -> receive never -> ok end end, 10)).

native_cleanup_classification_test() ->
    Case = #{category => test, name => cleanup},
    ?assertMatch(#{status := timeout, detail := {native_cleanup_timeout, 1}},
        execute(Case, fun() -> await_native(fun() -> false end, 1) end, 100)),
    ?assertMatch(#{status := timeout, detail := {native_entry_timeout, 1}},
        execute(Case, fun() -> error({native_entry_timeout, 1}) end, 100)),
    ?assertMatch(#{status := failed},
        execute(Case, fun() -> await(fun() -> false end, 1) end, 100)).

selection_test() ->
    ?assertNot(lists:any(fun(C) -> maps:get(category, C) == stress end, plan(#{profile => smoke}))),
    ?assert(lists:all(fun(C) -> maps:get(category, C) == stress end, plan(#{profile => stress}))),
    ?assertError({unknown_category, missing}, cases(missing)),
    ?assertError({unknown_cases, [missing]}, plan(#{profile => smoke, cases => [missing]})).
-endif.
