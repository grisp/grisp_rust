//! Private probe bindings, checked against both SDKs by check_abi.py.
//! RTEMS enables the sporadic-server fields even when the policy is FIFO/RR.
use core::ffi::{c_int, c_long, c_ulong};

/// SDK pthread handle; these private bindings are for the ARM RTEMS probes only.
pub type Pthread = c_ulong;
/// Process identifier accepted by sched_rr_get_interval (zero means this process).
pub type Pid = c_int;
pub const SCHED_RR: c_int = 2;

/// RTEMS time_t is 64-bit even on ARM32; c_long retains the SDK nanosecond width.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct Timespec {
    pub tv_sec: i64,
    pub tv_nsec: c_long,
}

/// Preserve every SDK field: pthread_getschedparam writes the whole structure,
/// including sporadic-server storage unused by this RR probe.
#[repr(C)]
#[derive(Clone, Copy, Default)]
pub struct SchedParam {
    pub sched_priority: c_int,
    pub sched_ss_low_priority: c_int,
    pub sched_ss_repl_period: Timespec,
    pub sched_ss_init_budget: Timespec,
    pub sched_ss_max_repl: c_int,
}

// Measured ARM RTEMS 5/6 ABI. The independent C comparison also checks fields.
const _: () = {
    assert!(core::mem::size_of::<SchedParam>() == 48);
    assert!(core::mem::align_of::<SchedParam>() == 8);
    assert!(core::mem::offset_of!(SchedParam, sched_ss_max_repl) == 40);
};

// Thin SDK calls: pthread scheduling functions return error numbers directly;
// sched_* failures return -1 and set errno. Callers own all output storage.
unsafe extern "C" {
    pub fn pthread_self() -> Pthread;
    pub fn pthread_getschedparam(
        thread: Pthread,
        policy: *mut c_int,
        param: *mut SchedParam,
    ) -> c_int;
    pub fn pthread_setschedparam(thread: Pthread, policy: c_int, param: *const SchedParam)
        -> c_int;
    pub fn sched_get_priority_min(policy: c_int) -> c_int;
    pub fn sched_get_priority_max(policy: c_int) -> c_int;
    pub fn sched_rr_get_interval(pid: Pid, interval: *mut Timespec) -> c_int;
}
