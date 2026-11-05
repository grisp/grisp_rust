//! Lifetime and IO probes using safe Rustler APIs. No borrowed environment is
//! retained by a worker. Gates/timeouts bound workers even if Erlang exits.
use super::{atoms, DropCounter, Probe, Worker};
use rustler::{Binary, Env, Error, LocalPid, Monitor, NifResult, OwnedEnv, ResourceArc, Term};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::Duration;

/// Map-shaped derive fixture; String decoding also checks UTF-8 validation.
#[derive(rustler::NifMap)]
struct Record {
    count: u64,
    label: String,
}
/// Fixed-arity tuple fixture, independent of the map representation.
#[derive(rustler::NifTuple)]
struct Pair {
    number: i64,
    label: String,
}
/// Tagged variants exercise Rustler's variant selection and rejection paths.
#[derive(rustler::NifTaggedEnum)]
enum Choice {
    Number(i64),
    Label(String),
}

/// Derived decoders must validate shapes/UTF-8; encoding must preserve the values.
#[rustler::nif]
fn derived_terms(record: Record, pair: Pair, choice: Choice) -> (Record, Pair, Choice) {
    (record, pair, choice)
}

/// One-way release latch: Erlang ends an owner lifetime before native work resumes.
struct Gate(Mutex<bool>, Condvar);
#[rustler::resource_impl]
impl rustler::Resource for Gate {}

impl Gate {
    /// A deadline prevents a detached worker waiting forever after a failed case.
    fn wait(&self) -> Result<(), String> {
        let (open, _) = self
            .1
            .wait_timeout_while(self.0.lock().unwrap(), Duration::from_secs(2), |open| {
                !*open
            })
            .map_err(|error| error.to_string())?;
        if *open {
            Ok(())
        } else {
            Err("worker gate timed out".into())
        }
    }
}

/// Private release gate; workers also expire after two seconds if Erlang dies.
#[rustler::nif]
fn new_gate() -> ResourceArc<Gate> {
    ResourceArc::new(Gate(Mutex::new(false), Condvar::new()))
}

/// Idempotently release all gated workers, including from Erlang cleanup paths.
#[rustler::nif]
fn release_gate(gate: ResourceArc<Gate>) -> bool {
    *gate.0.lock().unwrap() = true;
    gate.1.notify_all();
    true
}

/// Keep a Rust reference after the Erlang owner exits, then drop before sending done.
#[rustler::nif]
fn hold_resource(
    value: ResourceArc<Probe>,
    gate: ResourceArc<Gate>,
    recipient: LocalPid,
    token: u64,
) -> Result<bool, String> {
    let worker = Worker::new();
    std::thread::Builder::new()
        .name("rust-resource-hold".into())
        .stack_size(128 * 1024)
        .spawn(move || {
            let _worker = worker;
            let result = gate.wait().map(|()| *value.0.lock().unwrap());
            drop(value);
            let _ = OwnedEnv::new()
                .send_and_clear(&recipient, |_| (atoms::rust_resource_done(), token, result));
        })
        .map_err(|error| error.to_string())?;
    Ok(true)
}

/// Copy a supplied Erlang term before returning; only SavedTerm/OwnedEnv enter the worker.
#[rustler::nif]
fn owned_echo(
    term: Term,
    gate: ResourceArc<Gate>,
    recipient: LocalPid,
    token: u64,
) -> Result<bool, String> {
    let mut owned = OwnedEnv::new();
    let saved = owned.save(term);
    let worker = Worker::new();
    std::thread::Builder::new()
        .name("rust-owned-echo".into())
        .stack_size(128 * 1024)
        .spawn(move || {
            let _worker = worker;
            let result = gate.wait().map(|()| true);
            let _ = owned.send_and_clear(&recipient, |env| {
                (atoms::rust_owned_echo(), token, result, saved.load(env))
            });
        })
        .map_err(|error| error.to_string())?;
    Ok(true)
}

/// Binary backing storage with a case-local destructor counter.
struct Blob(Vec<u8>, ResourceArc<DropCounter>);
impl Drop for Blob {
    fn drop(&mut self) {
        self.1 .0.fetch_add(1, Ordering::SeqCst);
    }
}
#[rustler::resource_impl]
impl rustler::Resource for Blob {}

/// Binary must retain its Rust backing resource across process transfer and GC.
#[rustler::nif]
fn tracked_binary<'a>(env: Env<'a>, counter: ResourceArc<DropCounter>) -> Binary<'a> {
    let blob = ResourceArc::new(Blob((0..4096).map(|value| value as u8).collect(), counter));
    blob.make_binary(env, |blob| &blob.0)
}

/// Callback state shared with ERTS; a mismatch is reported by watch_count,
/// rather than panicking through the resource down callback.
struct Watch {
    monitor: Mutex<Option<Monitor>>,
    downs: AtomicUsize,
    pid: LocalPid,
    invalid: AtomicBool,
}
#[rustler::resource_impl]
impl rustler::Resource for Watch {
    // Validate callback identity before publishing completion to the polling test.
    fn down<'a>(&'a self, _env: Env<'a>, pid: LocalPid, monitor: Monitor) {
        if pid != self.pid || self.monitor.lock().unwrap().as_ref() != Some(&monitor) {
            self.invalid.store(true, Ordering::SeqCst);
        }
        self.downs.fetch_add(1, Ordering::SeqCst);
    }
}

/// Monitor one controlled recipient; an already-dead PID must return false.
/// The callback validates both the PID and the opaque monitor handle.
#[rustler::nif]
fn watch_process(env: Env, pid: LocalPid) -> (ResourceArc<Watch>, bool) {
    let watch = ResourceArc::new(Watch {
        monitor: Mutex::new(None),
        downs: AtomicUsize::new(0),
        pid,
        invalid: AtomicBool::new(false),
    });
    let registered = {
        // A concurrent down callback must see the handle after registration.
        let mut monitor = watch.monitor.lock().unwrap();
        *monitor = env.monitor(&watch, &pid);
        monitor.is_some()
    };
    (watch, registered)
}

/// Read completed callbacks and reject any recorded PID/monitor mismatch.
#[rustler::nif]
fn watch_count(watch: ResourceArc<Watch>) -> NifResult<usize> {
    // Observe completion before the validation flag: a counted callback must
    // not be accepted using an earlier, still-false invalid flag.
    let downs = watch.downs.load(Ordering::SeqCst);
    if watch.invalid.load(Ordering::SeqCst) {
        return Err(Error::RaiseAtom("invalid_monitor_callback"));
    }
    Ok(downs)
}

/// Remove the ERTS monitor; retain its handle for an already-racing callback.
#[rustler::nif]
fn cancel_watch(env: Env, watch: ResourceArc<Watch>) -> bool {
    let monitor = *watch.monitor.lock().unwrap();
    monitor.is_some_and(|monitor| env.demonitor(&watch, &monitor))
}

/// Per-call lifecycle witness retained by the Erlang coordinator during cleanup.
/// State zero may still mean queued; only state two proves native retirement.
struct SocketState(AtomicUsize);
#[rustler::resource_impl]
impl rustler::Resource for SocketState {}

/// Allocate a single-use witness so unrelated socket jobs cannot satisfy cleanup.
#[rustler::nif]
fn new_socket_state() -> ResourceArc<SocketState> {
    ResourceArc::new(SocketState(AtomicUsize::new(0)))
}

/// 0 = unused, 1 = callback active, 2 = callback finished (also on error/unwind).
#[rustler::nif]
fn socket_state(state: ResourceArc<SocketState>) -> usize {
    state.0.load(Ordering::SeqCst)
}

/// Publish retirement on every exit path, after the socket operation has returned.
struct SocketGuard(ResourceArc<SocketState>);
impl Drop for SocketGuard {
    fn drop(&mut self) {
        self.0 .0.store(2, Ordering::SeqCst);
    }
}

/// A real pending read: Erlang delays and fragments a 16-byte frame, then checks
/// the reversed reply. Connect/read/write timeouts bound native cleanup.
#[rustler::nif(schedule = "DirtyIo")]
fn socket_roundtrip(
    env: Env,
    state: ResourceArc<SocketState>,
    port: u16,
    recipient: LocalPid,
    token: u64,
) -> Result<(u32, i32), String> {
    let _worker = Worker::new();
    state
        .0
        .compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst)
        .map_err(|_| "socket state already used")?;
    let _state = SocketGuard(state);
    let address = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let check = || -> std::io::Result<()> {
        let mut stream = TcpStream::connect_timeout(&address, Duration::from_secs(2))?;
        stream.set_read_timeout(Some(Duration::from_secs(2)))?;
        stream.set_write_timeout(Some(Duration::from_secs(2)))?;
        stream.set_nodelay(true)?;
        env.send(&recipient, (atoms::rust_socket_waiting(), token))
            .map_err(|_| std::io::Error::other("socket peer exited"))?;
        let mut frame = [0u8; 16];
        stream.read_exact(&mut frame)?;
        if frame != std::array::from_fn(|index| index as u8) {
            return Err(std::io::Error::other("socket frame mismatch"));
        }
        frame.reverse();
        stream.write_all(&frame)
    };
    check().map_err(|error| format!("loopback socket: {error}"))?;
    Ok((16, super::current_thread_kind()))
}
