//! The minimal example NIF, separate from the validation suite.

/// Return a greeting for Erlang to print after startup; performs no native IO.
#[rustler::nif]
fn hello() -> &'static str {
    "Hello from a Rust NIF"
}

rustler::init!("grisp_rust_nif");
