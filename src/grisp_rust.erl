% @doc grisp_rust public API.
% @end
-module(grisp_rust).

-behavior(application).

% Callbacks
-export([start/2]).
-export([stop/1]).

%--- Callbacks -----------------------------------------------------------------

% Start supervision; delayed greeting/tests are scheduled by the suite server.
start(_Type, _Args) ->
    grisp_rust_sup:start_link().

stop(_State) -> ok.
