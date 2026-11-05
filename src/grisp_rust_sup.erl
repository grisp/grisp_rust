% @doc grisp_rust top level supervisor.
% @end
-module(grisp_rust_sup).

-behavior(supervisor).

% API
-export([start_link/0]).

% Callbacks
-export([init/1]).


%--- API -----------------------------------------------------------------------

start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).


%--- Callbacks -----------------------------------------------------------------

% Keep the autostart coordinator supervised; case failures are suite results,
% not supervisor restarts.
init([]) ->
    Suite = #{id => grisp_rust_testsuite_server,
              start => {grisp_rust_testsuite_server, start_link, []},
              restart => permanent, shutdown => 5000, type => worker},
    {ok, {{one_for_one, 3, 10}, [Suite]}}.
