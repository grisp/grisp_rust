%% @doc Opt-in bounded repetition. These checks do not measure leaks precisely
%% or establish real-time guarantees. Report the actual number of iterations.
-module(grisp_rust_test_stress).
-export([cases/0, run/2]).

%% Iteration-driven churn plus time-bounded overlap; all remain opt-in.
cases() ->
    [{call_cycles, "repeat allocation, decoding and checked calls", quiet},
     {resource_cycles, "drop thousands of Rust resources with their owner", quiet},
     {thread_cycles, "repeat TLS spawn/join/destructor cycles", quiet},
     {concurrent_callers, "eight Erlang callers repeatedly invoke Rust", quiet},
     {mixed_load, "sustained CPU work overlaps Erlang, Rust events and real socket IO", quiet}].

%% Repeat decoding/allocation under normal GC rather than retaining every result.
run(call_cycles, #{stress_iterations := Count}) ->
    lists:foreach(fun(_) ->
        42 = grisp_rust_testsuite_nifs:sum([19, 23]),
        true = grisp_rust_testsuite_nifs:allocation(),
        42 = grisp_rust_testsuite_nifs:resource_value(grisp_rust_testsuite_nifs:new_resource(42))
    end, lists:seq(1, Count)),
    {ok, #{iterations => Count}};
%% Drop a whole owner heap and require exactly the requested resource destructors.
run(resource_cycles, #{stress_iterations := Requested}) ->
    Count = min(Requested, 10000),
    Counter = grisp_rust_testsuite_nifs:new_drop_counter(),
    {Pid, Ref} = spawn_monitor(fun() ->
        lists:foreach(fun(_) -> _ = grisp_rust_testsuite_nifs:new_resource(42, Counter) end,
                      lists:seq(1, Count))
    end),
    try
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok;
            {'DOWN', Ref, process, Pid, Reason} -> error({resource_owner_failed, Reason})
        after 10000 -> error(resource_owner_timeout)
        end,
        grisp_rust_testsuite:await(fun() ->
            grisp_rust_testsuite_nifs:resource_drop_count(Counter) == Count
        end, 10000),
        {ok, #{resources_created => Count, drops_observed => Count}}
    after exit(Pid, kill), erlang:demonitor(Ref, [flush]) end;
%% Each threads/0 call creates and joins two TLS workers, including their destructors.
run(thread_cycles, #{stress_iterations := Requested}) ->
    Count = min(Requested, 2000),
    lists:foreach(fun(_) -> {ok, true} = grisp_rust_testsuite_nifs:threads() end, lists:seq(1, Count)),
    {ok, #{iterations => Count}};
%% Eight Erlang callers exercise shared NIF registration under repeated dispatch.
run(concurrent_callers, #{stress_iterations := Count}) ->
    Workers = [spawn_monitor(fun() ->
        lists:foreach(fun(_) -> 42 = grisp_rust_testsuite_nifs:add(19, 23) end, lists:seq(1, Count))
    end) || _ <- lists:seq(1, 8)],
    try
        lists:foreach(fun({Pid, Ref}) ->
            receive
                {'DOWN', Ref, process, Pid, normal} -> ok;
                {'DOWN', Ref, process, Pid, Reason} -> error({caller_failed, Reason})
            after 10000 -> error(concurrent_caller_timeout) end
        end, Workers),
        {ok, #{callers => 8, iterations_each => Count, calls => 8 * Count}}
    after lists:foreach(fun({Pid, Ref}) -> exit(Pid, kill), erlang:demonitor(Ref, [flush]) end, Workers) end;
%% Map the iteration option to 2..10 half-second CPU windows; report actual overlap.
run(mixed_load, #{stress_iterations := Count}) ->
    Rounds = max(2, min(10, Count div 1000)),
    Results = [mixed_round() || _ <- lists:seq(1, Rounds)],
    {ok, #{rounds => Rounds, cpu_jobs => Rounds, cpu_ms_each => 500,
           socket_roundtrips => Rounds,
           active_samples => lists:sum([maps:get(samples, R) || R <- Results]),
           async_events_during_cpu => lists:sum([maps:get(active_events, R) || R <- Results]),
           normal_iterations => lists:sum([maps:get(iterations, R) || R <- Results]),
           max_heartbeat_gap_ms => lists:max([maps:get(max_gap, R) || R <- Results])}}.

%% One CPU job at a time respects its per-kind active marker. Independent IO
%% and Rust worker jobs overlap it. Samples count only when native work is active.
mixed_round() ->
    Parent = self(),
    Token = erlang:unique_integer([positive, monotonic]),
    IoState = grisp_rust_testsuite_nifs:new_socket_state(),
    Cpu = spawn_monitor(fun() ->
        receive {Token, start_cpu} ->
            Parent ! {Token, cpu_done, grisp_rust_testsuite_nifs:dirty_cpu_work(Parent, Token, 500)}
        end
    end),
    try
        Normal = spawn_monitor(fun() ->
            receive {Token, start_normal} ->
                normal_work(Parent, Token, 0, 0, erlang:monotonic_time(millisecond))
            end
        end),
        Io = spawn_monitor(fun() ->
            Result = grisp_rust_test_io:socket(IoState, fun() ->
                Parent ! {Token, io_ready},
                receive {Token, start_io} ->
                    %% Observe overlap before replying, while Rust is still reading.
                    1 = grisp_rust_testsuite_nifs:socket_state(IoState),
                    Active = grisp_rust_testsuite_nifs:dirty_work_active(2, Token),
                    Parent ! {Token, io_overlap, Active}
                end
            end),
            Parent ! {Token, io_done, Result}
        end),
        try
            %% Socket setup and process creation must not consume the CPU window.
            receive
                {Token, io_ready} -> ok;
                {'DOWN', IoRef, process, IoPid, IoReason}
                        when {IoPid, IoRef} =:= Io -> error({mixed_io_setup, IoReason})
            after 3000 -> error(mixed_io_setup_timeout) end,
            Started = erlang:monotonic_time(millisecond),
            element(1, Cpu) ! {Token, start_cpu},
            receive {rust_test_started, Token} -> ok
            after 2000 -> error({native_entry_timeout, 2000}) end,
            element(1, Normal) ! {Token, start_normal},
            element(1, Io) ! {Token, start_io},
            {ok, true} = grisp_rust_testsuite_nifs:async_messages(Parent, Token, 3, 20),
            %% Completion flags are independent: different senders have no global order.
            %% first/last/ended delimit the observed CPU window; max_gap is diagnostic.
            Initial = #{cpu => false, io => false, normal => false, events => 0, async => false,
                        samples => 0, active_events => 0, io_active => false, iterations => 0,
                        first => undefined, last => Started, ended => Started, max_gap => 0},
            Collected = collect(Token, element(1, Normal), Started + 3000, Initial),
            Stats = Collected#{max_gap := max(maps:get(max_gap, Collected),
                maps:get(ended, Collected) - maps:get(last, Collected))},
            lists:foreach(fun({Pid, Ref}) ->
                receive {'DOWN', Ref, process, Pid, normal} -> ok
                after 2000 -> error(mixed_owner_timeout) end
            end, [Cpu, Normal, Io]),
            Span = case maps:get(first, Stats) of
                undefined -> 0;
                First -> maps:get(last, Stats) - First
            end,
            case Stats of
                #{samples := Samples, active_events := Events, io_active := true, iterations := Iterations}
                        when Samples >= 2, Events >= 1, Iterations > 0, Span >= 250 -> Stats;
                _ -> error({mixed_progress_not_observed, Stats})
            end
        after
            lists:foreach(fun({Pid, Ref}) ->
                exit(Pid, kill), erlang:demonitor(Ref, [flush])
            end, [Normal, Io]),
            grisp_rust_testsuite:await_native(fun() ->
                grisp_rust_testsuite_nifs:socket_state(IoState) == 2
            end, 3000)
        end
    after
        {CpuPid, CpuRef} = Cpu,
        exit(CpuPid, kill), erlang:demonitor(CpuRef, [flush]),
        grisp_rust_testsuite:await_native(fun() ->
            {Workers, _} = grisp_rust_testsuite_nifs:async_status(),
            Workers == 0 andalso not grisp_rust_testsuite_nifs:dirty_work_active(2, Token)
        end, 5000)
    end.

%% Drain every producer's completion protocol before checking progress or joining.
%% Normal samples carry their observation time; async activity is sampled on receipt.
collect(_, _, _, #{cpu := true, io := true, normal := true, async := true} = Stats) -> Stats;
collect(Token, Normal, Deadline, Stats) ->
    Next = receive
        {Token, cpu_done, {ok, 2}} ->
            Normal ! stop,
            Stats#{cpu := true, ended := erlang:monotonic_time(millisecond)};
        {Token, cpu_done, Other} -> error({mixed_cpu, Other});
        {Token, io_overlap, Active} -> Stats#{io_active := Active};
        {Token, io_done, {ok, _}} -> Stats#{io := true};
        {Token, normal_done, Count, _Checksum} -> Stats#{normal := true, iterations := Count};
        {Token, normal_progress, true, Now} ->
            First = case maps:get(first, Stats) of undefined -> Now; Value -> Value end,
            Stats#{samples := maps:get(samples, Stats) + 1, last := Now,
                   first := First,
                   max_gap := max(maps:get(max_gap, Stats), Now - maps:get(last, Stats))};
        {Token, normal_progress, false, _} -> Stats;
        {rust_test_event, Token, Sequence, <<"payload">>} ->
            Sequence = maps:get(events, Stats) + 1,
            Active = grisp_rust_testsuite_nifs:dirty_work_active(2, Token),
            Stats#{events := Sequence, active_events := maps:get(active_events, Stats) +
                   case Active of true -> 1; false -> 0 end};
        {rust_test_done, Token, 3} ->
            3 = maps:get(events, Stats), Stats#{async := true};
        {'DOWN', _, process, Pid, Reason} when Reason =/= normal -> error({mixed_worker_exit, Pid, Reason})
    after max(0, Deadline - erlang:monotonic_time(millisecond)) -> error({mixed_deadline, Stats}) end,
    collect(Token, Normal, Deadline, Next).

%% Deliberately keep a normal Erlang process runnable. Erlang reductions must
%% share its scheduler with the coordinator, and OS scheduling with native work.
normal_work(Parent, Token, Count, Checksum, Next) ->
    receive stop -> Parent ! {Token, normal_done, Count, Checksum}
    after 0 ->
        Value = lists:foldl(fun(N, Acc) -> (Acc + N) band 16#ffffffff end, Checksum, lists:seq(1, 200)),
        Now = erlang:monotonic_time(millisecond),
        NextSample = case Now >= Next of
            true ->
                Parent ! {Token, normal_progress, grisp_rust_testsuite_nifs:dirty_work_active(2, Token), Now},
                Now + 10;
            false -> Next
        end,
        normal_work(Parent, Token, Count + 200, Value, NextSample)
    end.
