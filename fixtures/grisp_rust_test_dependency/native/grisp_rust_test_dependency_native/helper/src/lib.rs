//! Ordinary helper registrations, without an init entry of their own.
use std::sync::Mutex;

pub struct Probe(pub Mutex<u64>);

#[rustler::resource_impl(name = "probe")]
impl rustler::Resource for Probe {}

#[rustler::nif]
fn helper_id() -> &'static str {
    "external_helper"
}
