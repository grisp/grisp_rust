%% @doc Rust-created workers must return promptly, send owned terms, and clean up.
%% Each case uses a fresh integer token and bounded waits; borrowed NIF terms
%% never enter the worker. Dead-recipient cases require an observed send failure.
-module(grisp_rust_test_async).
-export([cases/0, run/2]).

%% Exercise normal delivery, receiver death and Rustler's helper result/panic paths.
cases() ->
    [{messages, "ordered, tagged messages from a Rust worker", quiet},
     {dead_recipient, "send failure to an already-dead PID and worker cleanup", quiet},
     {receiver_exit, "receiver exits after first event; worker stops cleanly", quiet},
     {threaded_helper, "Rustler threaded helper delivers its encoded result", quiet},
     {threaded_panic, "Rustler threaded helper converts a worker panic", panic},
     {owned_term, "OwnedEnv preserves a nested term after its Erlang owner exits", quiet}].

%% Always wait for accepted native jobs to retire, even after an assertion fails.
run(Name, _) ->
    Token = erlang:unique_integer([positive, monotonic]),
    try check(Name, Token)
    after idle() end.

%% Correlate by token and require ordered events followed by the final marker.
check(messages, Token) ->
    {ok, true} = grisp_rust_testsuite_nifs:async_messages(self(), Token, 3, 10),
    lists:foreach(fun(Sequence) ->
        receive
            {rust_test_event, Token, Actual, <<"payload">>} -> Sequence = Actual;
            {rust_test_done, Token, _} -> error(premature_done_event)
        after 2000 -> error({missing_event, Sequence}) end
    end, [1, 2, 3]),
    receive
        {rust_test_done, Token, 3} -> ok;
        {rust_test_event, Token, _, _} -> error(extra_event)
    after 2000 -> error(missing_done_event) end;
%% DOWN establishes that a subsequent successful send would be a false positive.
check(dead_recipient, Token) ->
    {Pid, Ref} = spawn_monitor(fun() -> ok end),
    receive {'DOWN', Ref, process, Pid, normal} -> ok after 2000 -> error(receiver_timeout) end,
    {0, Before} = grisp_rust_testsuite_nifs:async_status(),
    {ok, true} = grisp_rust_testsuite_nifs:async_messages(Pid, Token, 3, 10),
    idle(),
    {0, After} = grisp_rust_testsuite_nifs:async_status(),
    true = After > Before, ok;
%% Stop a real recipient mid-stream and require the worker to observe send failure.
check(receiver_exit, Token) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        receive {rust_test_event, Token, 1, <<"payload">>} -> Parent ! {Token, received}
        after 2000 -> error(receiver_event_timeout) end
    end),
    try
        {0, Before} = grisp_rust_testsuite_nifs:async_status(),
        {ok, true} = grisp_rust_testsuite_nifs:async_messages(Pid, Token, 10, 10),
        receive {Token, received} -> ok after 2000 -> error(missing_receiver_ack) end,
        receive {'DOWN', Ref, process, Pid, normal} -> ok after 2000 -> error(receiver_exit_timeout) end,
        idle(),
        {0, After} = grisp_rust_testsuite_nifs:async_status(),
        true = After > Before, ok
    after exit(Pid, kill), erlang:demonitor(Ref, [flush]) end;
check(threaded_helper, Token) ->
    true = grisp_rust_testsuite_nifs:threaded_helper(Token, false),
    receive {rust_test_helper, Token, 42} -> ok after 2000 -> error(helper_result_timeout) end;
%% Release only after the original Erlang owner dies: the worker must own its copy.
check(owned_term, Token) ->
    Gate = grisp_rust_testsuite_nifs:new_gate(),
    Parent = self(),
    Reference = make_ref(),
    {Pid, Ref} = spawn_monitor(fun() ->
        {ok, true} = grisp_rust_testsuite_nifs:owned_echo(payload(Parent, Reference), Gate, Parent, Token)
    end),
    try
        receive
            {'DOWN', Ref, process, Pid, normal} -> ok;
            {'DOWN', Ref, process, Pid, Reason} -> error({term_owner_failed, Reason})
        after 2000 -> error(term_owner_timeout) end,
        true = grisp_rust_testsuite_nifs:release_gate(Gate),
        Expected = payload(Parent, Reference),
        receive {rust_owned_echo, Token, {ok, true}, Expected} -> ok
        after 2000 -> error(owned_term_mismatch) end
    after
        exit(Pid, kill), erlang:demonitor(Ref, [flush]),
        grisp_rust_testsuite_nifs:release_gate(Gate)
    end;
%% Rustler's helper sends an error term; this is separate from a NIF exception.
check(threaded_panic, Token) ->
    true = grisp_rust_testsuite_nifs:threaded_helper(Token, true),
    receive {error, <<"deliberate Rustler helper panic">>} -> ok
    after 2000 -> error(helper_panic_timeout) end.

%% Counter-based cleanup is valid here because each job was accepted before returning.
idle() ->
    grisp_rust_testsuite:await_native(fun() ->
        {Active, _} = grisp_rust_testsuite_nifs:async_status(), Active == 0
    end, 5000).

%% Rebuild the same value for comparison without retaining the owner's original term.
payload(Pid, Ref) ->
    #{pid => Pid, reference => Ref, nested => {tag, [1, -2, 16#ffffffffffffffff]},
      binary => binary:copy(<<0,1,255>>, 1024)}.
