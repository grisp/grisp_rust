%% @doc Separate NIF registration and same-named resource fixture for the suite.
-module(grisp_rust_test_dependency_nif).
-export([multiply/2, module_id/0, feature_enabled/0, helper_id/0, new_resource/1, resource_value/1]).
-on_load(init/0).
-include("cargo.hrl").

%% Resolve the dependency crate independently, including in the aggregate archive.
init() -> ?load_nif_from_crate("grisp_rust_test_dependency_native", 0).

%% Checked signed multiplication; overflow raises the overflow atom.
multiply(_A, _B) -> erlang:nif_error(nif_not_loaded).
%% The dependency identity must survive aggregate registration.
module_id() -> erlang:nif_error(nif_not_loaded).
%% Assert that the Erlang build propagated the dependency-probe Cargo feature.
feature_enabled() -> erlang:nif_error(nif_not_loaded).
%% A helper crate contributes its NIF through ordinary upstream registration.
helper_id() -> erlang:nif_error(nif_not_loaded).
%% Own a module-scoped probe; the suite module must reject it as a foreign type.
new_resource(_Value) -> erlang:nif_error(nif_not_loaded).
%% Read only dependency-owned probes; another module's probe raises badarg.
resource_value(_Resource) -> erlang:nif_error(nif_not_loaded).
