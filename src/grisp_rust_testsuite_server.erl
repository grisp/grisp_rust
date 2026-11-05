%% @doc Schedule suite autostart without delaying BEAM/application startup.
-module(grisp_rust_testsuite_server).
-behavior(gen_server).
-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% @doc Start the supervised autostart coordinator, not the tests themselves.
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% Delay the greeting and configured run so native output is separate from startup noise.
%% State holds only the pending timer and the monitored run process.
init([]) ->
    process_flag(trap_exit, true),
    Auto = application:get_env(grisp_rust, testsuite_autostart, true),
    Delay = application:get_env(grisp_rust, testsuite_delay_ms, 5000),
    true = is_boolean(Auto),
    true = is_integer(Delay) andalso Delay >= 0,
    Timer = case Auto of true -> erlang:send_after(Delay, self(), run); false -> undefined end,
    {ok, #{timer => Timer, worker => undefined}}.

%% Expose autostart state for inspection without starting a second run.
handle_call(status, _From, State) -> {reply, State, State};
handle_call(_, _From, State) -> {reply, {error, unsupported}, State}.
handle_cast(_, State) -> {noreply, State}.

%% Keep execution in a monitored worker so the server stays responsive during tests.
handle_info(run, #{worker := undefined} = State) ->
    io:format("~n~ts~n", [grisp_rust_nif:hello()]),
    Options = #{profile => application:get_env(grisp_rust, testsuite_profile, smoke),
                scratch_root => application:get_env(grisp_rust, testsuite_scratch_root, "/tmp")},
    {Pid, Ref} = spawn_monitor(fun() ->
        case grisp_rust_testsuite:run(Options) of
            {error, Reason} -> logger:error("Rust testsuite could not run: ~p", [Reason]);
            _ -> ok
        end
    end),
    {noreply, State#{timer := undefined, worker := {Pid, Ref}}};
handle_info({'DOWN', Ref, process, Pid, Reason}, #{worker := {Pid, Ref}} = State) ->
    case Reason of normal -> ok; _ -> logger:error("Rust testsuite runner exited: ~p", [Reason]) end,
    {noreply, State#{worker := undefined}};
handle_info(_, State) -> {noreply, State}.

%% Cancel autostart and stop its Erlang runner; native cancellation is not implied.
terminate(_, State) ->
    case maps:get(timer, State) of undefined -> ok; Timer -> erlang:cancel_timer(Timer) end,
    %% Stopping an Erlang process cannot cancel a native callback already in progress.
    case maps:get(worker, State) of undefined -> ok; {Pid, _} -> exit(Pid, shutdown) end,
    ok.
