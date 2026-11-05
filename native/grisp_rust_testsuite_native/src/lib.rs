//! Small probes for the Erlang-driven validation suite.
//!
//! Blocking probes use dirty schedulers. Async probes move only PIDs and owned
//! Rust values into workers; no borrowed NIF environment crosses a thread boundary.
use rustler::{Binary, Encoder, Env, Error, LocalPid, NewBinary, NifResult, OwnedEnv, ResourceArc};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

mod integration;
#[cfg(target_os = "rtems")]
mod rtems;
mod std_checks;

mod atoms {
    rustler::atoms! { rust_test_event, rust_test_done, rust_test_helper, rust_test_started,
    rust_resource_done, rust_owned_echo, rust_socket_waiting }
}

// Cumulative drop/send diagnostics; cases compare deltas or independent DropCounters.
// ACTIVE_WORKERS includes accepted jobs before spawn, avoiding a startup-zero race.
static PANIC_DROPS: AtomicUsize = AtomicUsize::new(0);
static RESOURCE_DROPS: AtomicUsize = AtomicUsize::new(0);
static ACTIVE_WORKERS: AtomicUsize = AtomicUsize::new(0);
static SEND_FAILURES: AtomicUsize = AtomicUsize::new(0);

/// Case-local destruction evidence, shared without retaining the probed resource.
struct DropCounter(AtomicUsize);
#[rustler::resource_impl]
impl rustler::Resource for DropCounter {}

/// Mutable resource deliberately named "probe" in two different NIF modules.
/// Cross-module decoding must reject the dependency's distinct resource type.
struct Probe(Mutex<u64>, Option<ResourceArc<DropCounter>>);
impl Drop for Probe {
    fn drop(&mut self) {
        RESOURCE_DROPS.fetch_add(1, Ordering::SeqCst);
        if let Some(counter) = &self.1 {
            counter.0.fetch_add(1, Ordering::SeqCst);
        }
    }
}
#[rustler::resource_impl(name = "probe")]
impl rustler::Resource for Probe {}

/// Identify the loaded registration table when several NIFs share one archive.
#[rustler::nif]
fn module_id() -> &'static str {
    "testsuite"
}

#[derive(rustler::NifMap)]
struct BuildVersions {
    rust: String,
    libc: String,
    inventory: String,
    rustler: String,
}

/// Versions recorded by the host build, available without tools on the device.
#[rustler::nif]
fn build_versions() -> BuildVersions {
    BuildVersions {
        rust: env!("SUITE_RUST_VERSION").into(),
        libc: env!("SUITE_LIBC_VERSION").into(),
        inventory: env!("SUITE_INVENTORY_VERSION").into(),
        rustler: env!("SUITE_RUSTLER_VERSION").into(),
    }
}

/// Allocate a value without a case-local counter for conversion/isolation checks.
#[rustler::nif]
fn new_resource(value: u64) -> ResourceArc<Probe> {
    ResourceArc::new(Probe(Mutex::new(value), None))
}

/// An independent counter prevents unrelated resource drops satisfying a check.
#[rustler::nif]
fn new_drop_counter() -> ResourceArc<DropCounter> {
    ResourceArc::new(DropCounter(AtomicUsize::new(0)))
}
/// The two-argument constructor attributes destruction to this case alone.
#[rustler::nif(name = "new_resource")]
fn new_tracked_resource(value: u64, counter: ResourceArc<DropCounter>) -> ResourceArc<Probe> {
    ResourceArc::new(Probe(Mutex::new(value), Some(counter)))
}
/// Read one case's counter without retaining any of its probed resources.
#[rustler::nif(name = "resource_drop_count")]
fn tracked_drop_count(counter: ResourceArc<DropCounter>) -> usize {
    counter.0.load(Ordering::SeqCst)
}

/// Decode and read this module's resource; foreign resource types must be badarg.
#[rustler::nif]
fn resource_value(value: ResourceArc<Probe>) -> u64 {
    *value.0.lock().unwrap()
}

/// Cumulative drop diagnostic; exact-lifetime cases use the counter overload.
#[rustler::nif]
fn resource_drop_count() -> usize {
    RESOURCE_DROPS.load(Ordering::SeqCst)
}

/// Checked conversion/arithmetic: overflow becomes an Erlang exception.
#[rustler::nif]
fn add(a: i64, b: i64) -> NifResult<i64> {
    a.checked_add(b).ok_or(Error::RaiseAtom("overflow"))
}

/// Decode a list into a Vec, exercising BEAM-backed Rust allocation.
#[rustler::nif]
fn sum(values: Vec<i64>) -> NifResult<i64> {
    values.into_iter().try_fold(0i64, |acc, value| {
        acc.checked_add(value).ok_or(Error::RaiseAtom("overflow"))
    })
}

/// Allocate a BEAM binary and preserve bytes, including the empty case.
#[rustler::nif]
fn reverse_binary<'a>(env: Env<'a>, input: Binary<'a>) -> Binary<'a> {
    let mut output = NewBinary::new(env, input.len());
    for (dst, src) in output
        .as_mut_slice()
        .iter_mut()
        .zip(input.as_slice().iter().rev())
    {
        *dst = *src;
    }
    output.into()
}

/// Rustler must translate this panic and run the guard destructor exactly once.
#[rustler::nif]
fn panic_probe() -> bool {
    panic_with_drop()
}
/// Exercise Rustler's unwind boundary on a dirty CPU scheduler stack.
#[rustler::nif(schedule = "DirtyCpu")]
fn dirty_cpu_panic() -> bool {
    panic_with_drop()
}
/// Exercise the same unwind/destructor contract on a dirty IO scheduler stack.
#[rustler::nif(schedule = "DirtyIo")]
fn dirty_io_panic() -> bool {
    panic_with_drop()
}

/// Shared deliberate panic body; one destructor increment is required per call.
fn panic_with_drop() -> bool {
    struct Guard;
    impl Drop for Guard {
        fn drop(&mut self) {
            PANIC_DROPS.fetch_add(1, Ordering::SeqCst);
        }
    }
    let _guard = Guard;
    panic!("deliberate Rust NIF panic")
}
/// Let Erlang distinguish caught exceptions from unwinding that skipped cleanup.
#[rustler::nif]
fn panic_drop_count() -> usize {
    PANIC_DROPS.load(Ordering::SeqCst)
}

/// Basic std allocation and locking without spawning a worker.
#[rustler::nif]
fn allocation() -> bool {
    *Mutex::new(vec![19u64, 23]).lock().unwrap() == vec![19u64, 23]
}

// Keep standalone std checks reusable: the NIF layer only tags their Result
// and moves potentially blocking joins/waits off normal schedulers.
macro_rules! probe {
    ($name:ident) => {
        #[rustler::nif(schedule = "DirtyIo")]
        fn $name() -> Result<bool, String> {
            std_checks::$name().map(|()| true)
        }
    };
}
probe!(threads);
probe!(mutex);
probe!(rwlock);
probe!(condvar);
probe!(channels);
probe!(clock);
probe!(stdio);
probe!(poison);
probe!(worker_panic);
probe!(contention);
probe!(timeouts);
probe!(initialization);
probe!(context);

/// Run scratch-file operations off normal schedulers; the caller supplies a unique path.
#[rustler::nif(schedule = "DirtyIo")]
fn file_io(directory: String) -> Result<bool, String> {
    std_checks::file_io(&directory).map(|()| true)
}

/// Count accepted native jobs through spawn failure, return, or unwinding.
/// Zero alone cannot exclude a callback still queued in ERTS.
struct Worker;
impl Worker {
    fn new() -> Self {
        ACTIVE_WORKERS.fetch_add(1, Ordering::SeqCst);
        Self
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        ACTIVE_WORKERS.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Return immediately; send ordered, tagged messages from a bounded Rust worker.
/// A failed send stops the worker. Erlang checks the active-worker counter for cleanup.
#[rustler::nif]
fn async_messages(
    recipient: LocalPid,
    token: u64,
    count: u32,
    delay_ms: u64,
) -> Result<bool, String> {
    if count == 0 || count > 32 || delay_ms > 100 {
        return Err("worker limits exceeded".into());
    }
    let worker = Worker::new();
    std::thread::Builder::new()
        .name("rust-suite-events".into())
        .stack_size(128 * 1024)
        .spawn(move || {
            let _worker = worker;
            let mut owned = OwnedEnv::new();
            for sequence in 1..=count {
                std::thread::sleep(Duration::from_millis(delay_ms));
                if owned
                    .send_and_clear(&recipient, |_| {
                        (atoms::rust_test_event(), token, sequence, "payload")
                    })
                    .is_err()
                {
                    SEND_FAILURES.fetch_add(1, Ordering::SeqCst);
                    return;
                }
            }
            if owned
                .send_and_clear(&recipient, |_| (atoms::rust_test_done(), token, count))
                .is_err()
            {
                SEND_FAILURES.fetch_add(1, Ordering::SeqCst);
            }
        })
        .map_err(|error| error.to_string())?;
    Ok(true)
}

/// Return (active jobs, cumulative failed sends) for cleanup and dead-PID checks.
#[rustler::nif]
fn async_status() -> (usize, usize) {
    (
        ACTIVE_WORKERS.load(Ordering::SeqCst),
        SEND_FAILURES.load(Ordering::SeqCst),
    )
}

/// Use Rustler's threaded helper with the suite's explicit 128 KiB stack bound.
struct SuiteSpawner;
impl rustler::thread::JobSpawner for SuiteSpawner {
    fn spawn<F: FnOnce() + Send + std::panic::UnwindSafe + 'static>(job: F) {
        std::thread::Builder::new()
            .name("rust-suite-helper".into())
            .stack_size(128 * 1024)
            .spawn(job)
            .expect("could not spawn Rustler helper worker");
    }
}
/// Exercise Rustler's helper-owned environment and its worker-panic reply path.
#[rustler::nif]
fn threaded_helper(env: Env, token: u64, panic_worker: bool) -> bool {
    let worker = Worker::new();
    rustler::thread::spawn::<SuiteSpawner, _>(env, move |owned| {
        let _worker = worker;
        if panic_worker {
            panic!("deliberate Rustler helper panic");
        }
        (atoms::rust_test_helper(), token, 42).encode(owned)
    });
    true
}

/// ERTS callback kind: normal = 1, dirty CPU = 2, dirty IO = 3.
fn current_thread_kind() -> i32 {
    // enif_thread_type only queries the type of the current callback thread.
    unsafe { rustler::sys::enif_thread_type() }
}
/// Baseline identity for an ordinary, short NIF call.
#[rustler::nif]
fn normal_scheduler() -> i32 {
    current_thread_kind()
}
/// Verify registration actually dispatches to the dirty CPU pool.
#[rustler::nif(schedule = "DirtyCpu")]
fn dirty_cpu_scheduler() -> i32 {
    current_thread_kind()
}
/// Verify registration actually dispatches to the dirty IO pool.
#[rustler::nif(schedule = "DirtyIo")]
fn dirty_io_scheduler() -> i32 {
    current_thread_kind()
}

/// Read the current ERTS pthread without modifying its scheduling policy.
fn scheduler_priority() -> Result<(i32, i32), String> {
    #[cfg(target_os = "rtems")]
    {
        rtems::priority()
    }
    #[cfg(not(target_os = "rtems"))]
    {
        Err("rtems_only".into())
    }
}
/// Read (POSIX policy, priority) on the normal scheduler; hosts return rtems_only.
#[rustler::nif]
fn normal_scheduler_priority() -> Result<(i32, i32), String> {
    scheduler_priority()
}
/// Compare the dirty CPU pthread's policy/priority with the normal scheduler.
#[rustler::nif(schedule = "DirtyCpu")]
fn dirty_cpu_scheduler_priority() -> Result<(i32, i32), String> {
    scheduler_priority()
}
/// Include dirty IO in the inherited scheduler-policy readback.
#[rustler::nif(schedule = "DirtyIo")]
fn dirty_io_scheduler_priority() -> Result<(i32, i32), String> {
    scheduler_priority()
}
/// Report parent/child policy and priority plus RR quantum in microseconds.
/// The child is a joined std thread; scheduler threads are never modified.
#[rustler::nif(schedule = "DirtyIo")]
fn worker_inheritance() -> Result<(i32, i32, i32, i32, u64), String> {
    #[cfg(target_os = "rtems")]
    {
        rtems::inheritance()
    }
    #[cfg(not(target_os = "rtems"))]
    {
        Err("rtems_only".into())
    }
}

/// ARM32 pointer-width rejection and full-width integer/FP roundtrips.
#[rustler::nif]
fn numeric_edges(signed: i64, unsigned: u64, word: usize, float: f64) -> (i64, u64, usize, f64) {
    (signed, unsigned, word, float)
}

/// Exercise checked narrowing on both 32-bit boards and 64-bit development hosts.
#[rustler::nif]
fn numeric_narrow(signed: i8, unsigned: u8, signed16: i16, unsigned16: u16) -> (i8, u8, i16, u16) {
    (signed, unsigned, signed16, unsigned16)
}
/// Change only a disposable std worker's priority, verify it, then restore it.
#[rustler::nif(schedule = "DirtyIo")]
fn realtime_priority_upgrade() -> Result<(i32, i32, i32, i32, i32, i32), String> {
    #[cfg(target_os = "rtems")]
    {
        rtems::priority_upgrade()
    }
    #[cfg(not(target_os = "rtems"))]
    {
        Err("rtems_only".into())
    }
}

// One active token per work kind; matching the exact token excludes stale jobs.
static DIRTY_CPU_WORK: AtomicUsize = AtomicUsize::new(0);
static DIRTY_IO_WORK: AtomicUsize = AtomicUsize::new(0);
/// Clear the native-entry witness on success, error, and unwind.
struct ActiveWork(&'static AtomicUsize);
impl ActiveWork {
    /// Reserve a nonzero token; overlapping work of the same kind is rejected.
    fn start(slot: &'static AtomicUsize, token: usize) -> Result<Self, String> {
        if token == 0
            || slot
                .compare_exchange(0, token, Ordering::SeqCst, Ordering::SeqCst)
                .is_err()
        {
            return Err("invalid token or work already active".into());
        }
        Ok(Self(slot))
    }
}
impl Drop for ActiveWork {
    fn drop(&mut self) {
        self.0.store(0, Ordering::SeqCst);
    }
}
/// Only an observation made while the native callback is active counts as progress.
#[rustler::nif]
fn dirty_work_active(kind: i32, token: usize) -> NifResult<bool> {
    let slot = match kind {
        2 => &DIRTY_CPU_WORK,
        3 => &DIRTY_IO_WORK,
        _ => return Err(Error::BadArg),
    };
    Ok(token != 0 && slot.load(Ordering::SeqCst) == token)
}

/// Announce native entry before bounded work so Erlang can test another process
/// on the caller's normal scheduler while the dirty callback is still running.
#[rustler::nif(schedule = "DirtyCpu")]
fn dirty_cpu_work(env: Env, observer: LocalPid, token: usize, millis: u64) -> Result<i32, String> {
    cpu_work(env, observer, token, millis, false)
}
/// Yielding control distinguishes OS CPU starvation from broken dirty dispatch.
#[rustler::nif(schedule = "DirtyCpu")]
fn dirty_cpu_yielding_work(
    env: Env,
    observer: LocalPid,
    token: usize,
    millis: u64,
) -> Result<i32, String> {
    cpu_work(env, observer, token, millis, true)
}
/// Bounded busy work; the iteration cap also terminates if the clock stalls.
fn cpu_work(
    env: Env,
    observer: LocalPid,
    token: usize,
    millis: u64,
    yielding: bool,
) -> Result<i32, String> {
    if millis > 500 {
        return Err("work limit exceeded".into());
    }
    let _active = ActiveWork::start(&DIRTY_CPU_WORK, token)?;
    env.send(&observer, (atoms::rust_test_started(), token))
        .map_err(|_| "observer exited".to_string())?;
    let start = Instant::now();
    let mut value = 0u64;
    while start.elapsed() < Duration::from_millis(millis) && value < 100_000_000 {
        value = std::hint::black_box(value.wrapping_add(1));
        if yielding && value & 255 == 0 {
            std::thread::yield_now();
        }
    }
    if start.elapsed() < Duration::from_millis(millis) {
        return Err("CPU work reached iteration cap before its clock deadline".into());
    }
    Ok(current_thread_kind())
}
/// Sleeping control verifies blocking offload, not CPU fairness: FIFO can pass it.
#[rustler::nif(schedule = "DirtyIo")]
fn dirty_io_work(env: Env, observer: LocalPid, token: usize, millis: u64) -> Result<i32, String> {
    if millis > 500 {
        return Err("work limit exceeded".into());
    }
    let _active = ActiveWork::start(&DIRTY_IO_WORK, token)?;
    env.send(&observer, (atoms::rust_test_started(), token))
        .map_err(|_| "observer exited".to_string())?;
    std::thread::sleep(Duration::from_millis(millis));
    Ok(current_thread_kind())
}

rustler::init!("grisp_rust_testsuite_nifs");
