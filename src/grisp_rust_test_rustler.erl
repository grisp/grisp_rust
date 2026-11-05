%% @doc Registration scopes, dependency-owned NIFs, resources and the panic boundary.
-module(grisp_rust_test_rustler).
-export([cases/0, run/2]).

%% Include registration, ownership and unwind boundaries, not just arithmetic calls.
cases() ->
    [{multiple_modules, "greeting and testsuite registrations remain separate", quiet},
     {resources, "same-named resource types stay isolated between applications", quiet},
     {dependency, "a separate Erlang dependency loads its own Rust NIF", quiet},
     {resource_drop, "a terminated owner releases its resource", quiet},
     {worker_resource, "Rust reference outlives the Erlang owner and drops exactly once", quiet},
     {resource_binary, "resource-backed binary survives process transfer and GC", quiet},
     {resource_monitor, "Rustler down callback observes process exit and rejects dead PID", quiet},
     {resource_demonitor, "demonitor prevents a later down callback", quiet},
     {derived_terms, "map/tuple/tagged derives preserve values and reject bad UTF-8/shapes", quiet},
     {nif_panic, "ten caught NIF panics run destructors and permit later calls", panic},
     {dirty_cpu_panic, "dirty CPU panic unwinds and permits another pool job", panic},
     {dirty_io_panic, "dirty IO panic unwinds and permits another pool job", panic}].

%% Check the greeting and suite through their own registration tables.
run(multiple_modules, _) ->
    <<"Hello from a Rust NIF">> = grisp_rust_testsuite_nifs:hello(),
    <<"testsuite">> = grisp_rust_testsuite_nifs:module_id(),
    false = erlang:function_exported(grisp_rust_nif, add, 2), ok;
%% Equal resource names must not allow decoding another module's resource.
run(resources, _) ->
    First = grisp_rust_testsuite_nifs:new_resource(19),
    Second = grisp_rust_testsuite_nifs:dependency_resource(23),
    19 = grisp_rust_testsuite_nifs:resource_value(First),
    23 = grisp_rust_testsuite_nifs:dependency_resource_value(Second),
    badarg(fun() -> grisp_rust_testsuite_nifs:resource_value(Second) end),
    badarg(fun() -> grisp_rust_testsuite_nifs:dependency_resource_value(First) end);
run(dependency, _) ->
    42 = grisp_rust_testsuite_nifs:dependency_answer(),
    <<"dependency">> = grisp_rust_testsuite_nifs:dependency_id(),
    true = grisp_rust_testsuite_nifs:dependency_feature(),
    <<"external_helper">> = grisp_rust_test_dependency_nif:helper_id(), ok;
%% A case-local counter avoids unrelated GC satisfying the destructor assertion.
run(resource_drop, _) ->
    Counter = grisp_rust_testsuite_nifs:new_drop_counter(),
    {Pid, Ref} = spawn_monitor(fun() ->
        42 = grisp_rust_testsuite_nifs:resource_value(grisp_rust_testsuite_nifs:new_resource(42, Counter))
    end),
    try
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok;
            {'DOWN', Ref, process, Pid, Reason} -> error({resource_owner_failed, Reason})
        after 2000 -> error(resource_owner_timeout) end,
        grisp_rust_testsuite:await(fun() -> grisp_rust_testsuite_nifs:resource_drop_count(Counter) == 1 end, 2000)
    after exit(Pid, kill), erlang:demonitor(Ref, [flush]) end;
%% The Rust-held reference must survive owner DOWN, then release exactly once.
run(worker_resource, _) ->
    Counter = grisp_rust_testsuite_nifs:new_drop_counter(),
    Gate = grisp_rust_testsuite_nifs:new_gate(),
    Token = erlang:unique_integer([positive, monotonic]),
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Resource = grisp_rust_testsuite_nifs:new_resource(42, Counter),
        {ok, true} = grisp_rust_testsuite_nifs:hold_resource(Resource, Gate, Parent, Token)
    end),
    try
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok;
            {'DOWN', Ref, process, Pid, Reason} -> error({resource_owner_failed, Reason})
        after 2000 -> error(resource_owner_timeout) end,
        0 = grisp_rust_testsuite_nifs:resource_drop_count(Counter),
        true = grisp_rust_testsuite_nifs:release_gate(Gate),
        receive {rust_resource_done, Token, {ok, 42}} -> ok after 2000 -> error(resource_worker_timeout) end,
        grisp_rust_testsuite:await(fun() -> grisp_rust_testsuite_nifs:resource_drop_count(Counter) == 1 end, 2000)
    after
        exit(Pid, kill), erlang:demonitor(Ref, [flush]),
        grisp_rust_testsuite_nifs:release_gate(Gate),
        native_idle()
    end;
%% Keep binary data out of this coordinator's heap: only the holder may retain it.
%% Owner exit and holder GC must leave its resource alive until holder exit.
run(resource_binary, _) ->
    Counter = grisp_rust_testsuite_nifs:new_drop_counter(),
    Parent = self(),
    {Holder, HeldRef} = spawn_monitor(fun() ->
        receive {binary, Binary} ->
            Parent ! {self(), held, byte_size(Binary)},
            receive release -> Parent ! {self(), checked, binary:first(Binary), binary:last(Binary)} end
        end
    end),
    {Owner, OwnerRef} = spawn_monitor(fun() ->
        Holder ! {binary, grisp_rust_testsuite_nifs:tracked_binary(Counter)}
    end),
    try
        receive {Holder, held, 4096} -> ok after 2000 -> error(binary_transfer_timeout) end,
        receive
            {'DOWN', OwnerRef, process, Owner, normal} -> ok;
            {'DOWN', OwnerRef, process, Owner, Reason} -> error({binary_owner_failed, Reason})
        after 2000 -> error(binary_owner_timeout) end,
        true = erlang:garbage_collect(Holder),
        0 = grisp_rust_testsuite_nifs:resource_drop_count(Counter),
        Holder ! release,
        receive {Holder, checked, 0, 255} -> ok after 2000 -> error(binary_contents) end,
        receive {'DOWN', HeldRef, process, Holder, normal} -> ok after 2000 -> error(binary_holder_timeout) end,
        grisp_rust_testsuite:await(fun() -> grisp_rust_testsuite_nifs:resource_drop_count(Counter) == 1 end, 2000)
    after
        exit(Owner, kill), exit(Holder, kill),
        erlang:demonitor(OwnerRef, [flush]), erlang:demonitor(HeldRef, [flush])
    end;
run(resource_monitor, _) -> monitor_check(false);
run(resource_demonitor, _) -> monitor_check(true);
%% Check each derive's actual error contract; not every decoder raises badarg.
run(derived_terms, _) ->
    Map = #{count => 16#ffffffffffffffff, label => <<"grüße"/utf8>>},
    Pair = {-19, <<"tuple">>},
    Choice = {label, <<"enum">>},
    Expected = {Map, Pair, Choice},
    Expected = grisp_rust_testsuite_nifs:derived_terms(Map, Pair, Choice),
    badarg(fun() -> grisp_rust_testsuite_nifs:derived_terms(#{count => 1}, Pair, Choice) end),
    try grisp_rust_testsuite_nifs:derived_terms(Map#{label := <<255>>}, Pair, Choice) of
        _ -> error(expected_utf8_error)
    catch error:Message when is_binary(Message), byte_size(Message) > 0 -> ok end,
    badarg(fun() -> grisp_rust_testsuite_nifs:derived_terms(Map, {wrong}, Choice) end),
    try grisp_rust_testsuite_nifs:derived_terms(Map, Pair, {unknown, 42}) of
        _ -> error(expected_variant_error)
    catch error:invalid_variant -> ok end;
run(dirty_cpu_panic, _) -> dirty_panic(dirty_cpu_panic, dirty_cpu_scheduler, 2);
run(dirty_io_panic, _) -> dirty_panic(dirty_io_panic, dirty_io_scheduler, 3);
%% Repeat recovery and count destructors; a translated exception alone is insufficient.
run(nif_panic, _) ->
    Before = grisp_rust_testsuite_nifs:panic_drop_count(),
    lists:foreach(fun(_) ->
        try grisp_rust_testsuite_nifs:panic_probe() of _ -> error(expected_panic)
        catch error:nif_panicked -> ok end,
        42 = grisp_rust_testsuite_nifs:add(19, 23),
        <<"Hello from a Rust NIF">> = grisp_rust_testsuite_nifs:hello()
    end, lists:seq(1, 10)),
    Expected = Before + 10,
    Expected = grisp_rust_testsuite_nifs:panic_drop_count(), ok.

%% Reject foreign resources or malformed terms with the expected decoder exception.
badarg(Fun) ->
    try Fun() of _ -> error(expected_badarg) catch error:badarg -> ok end.

%% Keep the target alive through registration; optionally cancel before its exit.
%% Compare the Rust resource callback with Erlang DOWN, then reject an already-dead PID.
monitor_check(Cancel) ->
    {Pid, Ref} = spawn_monitor(fun() -> receive stop -> ok end end),
    try
        {Watch, true} = grisp_rust_testsuite_nifs:watch_process(Pid),
        0 = grisp_rust_testsuite_nifs:watch_count(Watch),
        case Cancel of true -> true = grisp_rust_testsuite_nifs:cancel_watch(Watch); false -> ok end,
        Pid ! stop,
        receive {'DOWN', Ref, process, Pid, normal} -> ok after 2000 -> error(monitored_exit_timeout) end,
        case Cancel of
            true -> 0 = grisp_rust_testsuite_nifs:watch_count(Watch);
            false -> grisp_rust_testsuite:await(fun() -> grisp_rust_testsuite_nifs:watch_count(Watch) == 1 end, 2000)
        end,
        {DeadWatch, false} = grisp_rust_testsuite_nifs:watch_process(Pid),
        0 = grisp_rust_testsuite_nifs:watch_count(DeadWatch),
        ok
    after exit(Pid, kill), erlang:demonitor(Ref, [flush]) end.

%% Do not start another case while a detached Rust worker still owns resources.
native_idle() ->
    grisp_rust_testsuite:await_native(fun() ->
        {Active, _} = grisp_rust_testsuite_nifs:async_status(), Active == 0
    end, 5000).

%% Require one guard drop and a later successful call on the same scheduler pool.
dirty_panic(Function, Identity, Kind) ->
    Before = grisp_rust_testsuite_nifs:panic_drop_count(),
    try apply(grisp_rust_testsuite_nifs, Function, []) of _ -> error(expected_panic)
    catch error:nif_panicked -> ok end,
    Kind = apply(grisp_rust_testsuite_nifs, Identity, []),
    Expected = Before + 1,
    Expected = grisp_rust_testsuite_nifs:panic_drop_count(),
    ok.
