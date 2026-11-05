%% @doc Check actual ERTS callback types and normal-scheduler responsiveness.
%% The heartbeat is bound to the caller's scheduler. Its acknowledgement must
%% sample the native active token before work completes. On one CPU, a FIFO
%% policy without timeslicing can starve the normal scheduler. The pure CPU
%% case detects that integration limitation; the yielding case distinguishes it.
-module(grisp_rust_test_scheduling).
-export([cases/0, run/2]).

%% Identity, policy and progress are separate contracts; host policy probes skip explicitly.
cases() ->
    [{normal_scheduler, "normal NIF executes on a normal scheduler", quiet},
     {dirty_cpu_scheduler, "DirtyCpu registration selects a dirty CPU thread", quiet},
     {dirty_io_scheduler, "DirtyIo registration selects a dirty IO thread", quiet},
     {scheduler_priorities, "report RTEMS normal, dirty CPU and dirty IO policies", quiet},
     {worker_inheritance, "Rust worker inherits RR and reports its quantum", quiet},
     {dirty_cpu_responsive, "normal scheduler responds during dirty CPU work", quiet},
     {dirty_cpu_yielding, "normal scheduler responds when dirty CPU work yields", quiet},
     {dirty_io_responsive, "normal scheduler responds while dirty IO sleeps", quiet},
     {realtime_priority, "raise a Rust worker priority by one and restore it", quiet}].

%% Match enif_thread_type identities, rather than trusting the declared NIF flags.
run(normal_scheduler, _) -> 1 = grisp_rust_testsuite_nifs:normal_scheduler(), ok;
run(dirty_cpu_scheduler, _) -> 2 = grisp_rust_testsuite_nifs:dirty_cpu_scheduler(), ok;
run(dirty_io_scheduler, _) -> 3 = grisp_rust_testsuite_nifs:dirty_io_scheduler(), ok;
run(dirty_cpu_responsive, _) -> responsive(dirty_cpu_work, 2);
run(dirty_cpu_yielding, _) -> responsive(dirty_cpu_yielding_work, 2);
run(dirty_io_responsive, _) -> responsive(dirty_io_work, 3);
%% RR at equal POSIX priority is the GRiSP runtime contract for all three pools.
run(scheduler_priorities, _) ->
    case {grisp_rust_testsuite_nifs:normal_scheduler_priority(),
          grisp_rust_testsuite_nifs:dirty_cpu_scheduler_priority(),
          grisp_rust_testsuite_nifs:dirty_io_scheduler_priority()} of
        {{ok, Normal}, {ok, DirtyCpu}, {ok, DirtyIo}} ->
            case {Normal, DirtyCpu, DirtyIo} of
                {{2, Priority}, {2, Priority}, {2, Priority}} -> ok;
                _ -> error({unexpected_scheduler_policies, Normal, DirtyCpu, DirtyIo})
            end,
            {ok, #{normal_scheduler => policy(Normal), dirty_cpu_scheduler => policy(DirtyCpu),
                   dirty_io_scheduler => policy(DirtyIo)}};
        {{error, <<"rtems_only">>}, {error, <<"rtems_only">>}, {error, <<"rtems_only">>}} -> {skip, rtems_only};
        Other -> error({scheduler_priority_probe, Other})
    end;
run(worker_inheritance, _) ->
    case grisp_rust_testsuite_nifs:worker_inheritance() of
        {ok, {2, Priority, 2, Priority, QuantumUs}} when QuantumUs > 0 ->
            {ok, #{policy => sched_rr, parent_priority => Priority,
                   inherited_priority => Priority, quantum_us => QuantumUs}};
        {error, <<"rtems_only">>} -> {skip, rtems_only};
        Other -> error({worker_inheritance, Other})
    end;
%% A disposable std worker changes priority; the ERTS scheduler is never upgraded.
run(realtime_priority, _) ->
    case grisp_rust_testsuite_nifs:realtime_priority_upgrade() of
        {ok, {OldPolicy, OldPriority, Minimum, Maximum, Low, High}}
                when Low >= Minimum, High == Low + 1, High =< Maximum ->
            {ok, #{old_policy => OldPolicy, old_priority => OldPriority,
                   policy => sched_rr, minimum => Minimum, maximum => Maximum,
                   raised_from => Low, raised_to => High, restored => true}};
        {error, <<"rtems_only">>} -> {skip, rtems_only};
        Other -> error({realtime_priority_probe, Other})
    end.

%% Decode RTEMS policy values only for reporting; preserve unknown numeric policies.
policy({Policy, Priority}) ->
    Name = case Policy of 0 -> sched_other; 1 -> sched_fifo; 2 -> sched_rr; _ -> Policy end,
    #{policy => Name, priority => Priority}.

%% Native entry precedes the heartbeat; bind both Erlang processes to scheduler 1.
%% Require the exact job still active when sampled, not merely a fast final reply.
responsive(Function, Kind) -> responsive(Function, Kind, 300).
responsive(Function, Kind, Millis) ->
    Parent = self(),
    Started = erlang:monotonic_time(millisecond),
    Token = erlang:unique_integer([positive, monotonic]),
    {Pid, Monitor} = spawn_opt(fun() ->
        Value = apply(grisp_rust_testsuite_nifs, Function, [Parent, Token, Millis]),
        Parent ! {Token, done, Value}
    end, [monitor, {scheduler, 1}]),
    try
        receive {rust_test_started, Token} -> ok
        after 2000 -> error({native_entry_timeout, 2000}) end,
        {Heartbeat, HeartbeatMonitor} = spawn_opt(fun() ->
            Active = grisp_rust_testsuite_nifs:dirty_work_active(Kind, Token),
            Parent ! {Token, heartbeat, Active, erlang:monotonic_time(millisecond) - Started}
        end, [monitor, {scheduler, 1}]),
        try
            {Active, HeartbeatMs} = receive
                {Token, heartbeat, A, T} -> {A, T};
                {'DOWN', HeartbeatMonitor, process, Heartbeat, Reason} -> error({heartbeat_exited, Reason})
            after 2000 -> error(heartbeat_timeout) end,
            receive
                {Token, done, {ok, Kind}} -> ok;
                {Token, done, Other} -> error({dirty_result, Other});
                {'DOWN', Monitor, process, Pid, Reason2} -> error({dirty_owner_exited, Reason2})
            after 2000 -> error(dirty_completion_timeout) end,
            receive {'DOWN', Monitor, process, Pid, normal} -> ok after 2000 -> error(dirty_owner_timeout) end,
            Detail = #{native_active_when_sampled => Active, heartbeat_ms => HeartbeatMs,
                       elapsed_ms => erlang:monotonic_time(millisecond) - Started, work => Function},
            case Active of
                true -> {ok, Detail};
                false -> {error, Detail#{reason => normal_scheduler_did_not_respond_during_dirty_work}}
            end
        after exit(Heartbeat, kill), erlang:demonitor(HeartbeatMonitor, [flush]) end
    after
        exit(Pid, kill), erlang:demonitor(Monitor, [flush]),
        grisp_rust_testsuite:await_native(fun() ->
            not grisp_rust_testsuite_nifs:dirty_work_active(Kind, Token)
        end, 2000)
    end.

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

completed_work_is_not_progress_test() ->
    ?assertMatch({error, #{native_active_when_sampled := false}},
                 responsive(dirty_cpu_work, 2, 0)).
-endif.
