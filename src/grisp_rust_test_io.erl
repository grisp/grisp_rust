%% @doc Clocks, owned scratch-file cleanup and explicit stdout/stderr output.
-module(grisp_rust_test_io).
-export([cases/0, run/2, socket/1, socket/2]).

%% Files use a disposable directory; socket IO needs only local IPv4 loopback.
cases() ->
    [{clock, "monotonic sleep and wall-clock access", quiet},
     {file_io, "read/write/seek/metadata/readdir and errno", quiet},
     {stdio, "stdout/stderr writes and flushes", console},
     {socket, "pending Rust socket read permits Erlang progress and preserves framing", quiet}].

%% Never reuse an existing directory: native cleanup may remove only this case's scratch files.
run(file_io, #{scratch_root := Root}) ->
    Directory = filename:join(Root, "grisp-rust-" ++ integer_to_list(erlang:unique_integer([positive]))),
    grisp_rust_testsuite_nifs:file_io(unicode:characters_to_binary(Directory));
run(socket, _) -> socket(grisp_rust_testsuite_nifs:new_socket_state());
run(Name, _) -> apply(grisp_rust_testsuite_nifs, Name, []).

%% The delayed/fragmented writer is Erlang. It must run while a real read is
%% pending in Rust, then receive the exact reversed frame. No external peer.
%% State is caller-owned so mixed stress can confirm native retirement even if
%% this coordinator dies. A killed Erlang caller alone is not cancellation.
socket(State) -> socket(State, fun() -> ok end).

%% Mixed stress releases this barrier once the CPU workload has entered.
socket(State, Ready) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {packet, 0}, {ip, {127,0,0,1}}]),
    try
        {ok, {_, Port}} = inet:sockname(Listen),
        Parent = self(),
        Token = erlang:unique_integer([positive, monotonic]),
        %% Link propagates coordinator death; the native state still owns retirement evidence.
        {Pid, Ref} = spawn_opt(fun() ->
            Result = grisp_rust_testsuite_nifs:socket_roundtrip(State, Port, Parent, Token),
            Parent ! {Token, socket_done, Result}
        end, [link, monitor]),
        try
            Socket = case gen_tcp:accept(Listen, 3000) of
                {ok, Accepted} -> Accepted;
                {error, AcceptReason} ->
                    Native = receive
                        {Token, socket_done, NativeResult} -> NativeResult;
                        {'DOWN', Ref, process, Pid, NativeExit} -> {worker_exit, NativeExit}
                    after 0 -> pending end,
                    error({socket_accept, AcceptReason, Native})
            end,
            try
                %% The peer needs both fragments before replying. Do not hold
                %% the second tiny write waiting for an ACK of the first one.
                ok = inet:setopts(Socket, [{nodelay, true}]),
                receive
                    {rust_socket_waiting, Token} -> ok;
                    {Token, socket_done, Early} -> error({socket_setup, Early});
                    {'DOWN', Ref, process, Pid, Reason} -> error({socket_worker, Reason})
                after 3000 -> error(socket_start_timeout) end,
                %% Avoid lazy-loading timer.beam through the occupied dirty IO pool.
                receive after 20 -> ok end,
                1 = grisp_rust_testsuite_nifs:socket_state(State),
                Ready(),
                ok = gen_tcp:send(Socket, <<0,1,2,3,4>>),
                receive after 5 -> ok end,
                1 = grisp_rust_testsuite_nifs:socket_state(State),
                ok = gen_tcp:send(Socket, <<5,6,7,8,9,10,11,12,13,14,15>>),
                {ok, <<15,14,13,12,11,10,9,8,7,6,5,4,3,2,1,0>>} = gen_tcp:recv(Socket, 16, 3000),
                receive
                    {Token, socket_done, {ok, {16, 3}}} -> ok;
                    {Token, socket_done, Other} -> error({socket_result, Other});
                    {'DOWN', Ref, process, Pid, Exit} -> error({socket_worker, Exit})
                after 3000 -> error(socket_completion_timeout) end,
                receive {'DOWN', Ref, process, Pid, normal} -> ok
                after 3000 -> error(socket_owner_timeout) end,
                {ok, #{bytes => 16, fragmented => true, active_during_wait => true}}
            after gen_tcp:close(Socket) end
        after
            %% Unlink before explicit kill so cleanup cannot kill this live coordinator.
            unlink(Pid),
            exit(Pid, kill),
            erlang:demonitor(Ref, [flush]),
            grisp_rust_testsuite:await_native(fun() ->
                grisp_rust_testsuite_nifs:socket_state(State) == 2
            end, 3000)
        end
    after gen_tcp:close(Listen) end.
