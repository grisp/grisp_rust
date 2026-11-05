%% @doc Minimal Rust NIF example. The returned greeting is printed by Erlang.
-module(grisp_rust_nif).
-export([hello/0]).
-on_load(init/0).
-include("cargo.hrl").

%% Load by crate identity on the host or through static firmware registration.
init() -> ?load_nif_from_crate("grisp_rust_native", 0).
%% @doc Return the Rust greeting; Erlang controls when it is printed.
hello() -> erlang:nif_error(nif_not_loaded).
