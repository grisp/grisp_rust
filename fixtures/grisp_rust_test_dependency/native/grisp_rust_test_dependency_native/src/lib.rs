//! Dependency-owned NIFs prove archive aggregation, feature propagation and
//! module-scoped resource registration independently of the main application.
use rustler::{Error, NifResult, ResourceArc};
use std::sync::Mutex;

// The helper owns the type and its normal automatic Rustler registration.
use grisp_rust_external_helper::Probe;

/// Checked arithmetic reached through the dependency's Erlang public API.
#[rustler::nif]
fn multiply(a: i64, b: i64) -> NifResult<i64> {
    a.checked_mul(b).ok_or(Error::RaiseAtom("overflow"))
}

/// Detect registration-table mixups between aggregated NIF modules.
#[rustler::nif]
fn module_id() -> &'static str {
    "dependency"
}

/// Prove dependency Cargo features survive the aggregate static-library build.
#[rustler::nif]
fn feature_enabled() -> bool {
    cfg!(feature = "dependency-probe")
}

/// Create a dependency-owned resource for cross-module type rejection checks.
#[rustler::nif]
fn new_resource(value: u64) -> ResourceArc<Probe> {
    ResourceArc::new(Probe(Mutex::new(value)))
}

/// Accept only this module's Probe, even when another module uses the same name.
#[rustler::nif]
fn resource_value(value: ResourceArc<Probe>) -> u64 {
    *value.0.lock().unwrap()
}

rustler::init!("grisp_rust_test_dependency_nif");
