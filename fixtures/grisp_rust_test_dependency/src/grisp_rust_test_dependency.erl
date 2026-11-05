%% @doc Path dependency whose public API proves dependency-owned Rust NIF integration.
-module(grisp_rust_test_dependency).
-export([answer/0]).

%% @doc Reach the dependency's loader and checked Rust arithmetic through Erlang.
answer() -> grisp_rust_test_dependency_nif:multiply(6, 7).
