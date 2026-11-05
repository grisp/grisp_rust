//! Standalone std contracts reused by NIFs and the RTEMS harness.
//! Checks return diagnostics; deliberate panic cases are caught or joined locally.
use std::cell::RefCell;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex, OnceLock, RwLock, TryLockError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// Platform-independent outcome; the NIF wrapper encodes it as {ok,true}/{error,Binary}.
pub type Check = Result<(), String>;

/// Report a failed invariant without requiring Rustler or an Erlang environment.
fn require(condition: bool, message: &str) -> Check {
    if condition {
        Ok(())
    } else {
        Err(message.into())
    }
}

/// Give each std worker the same explicit stack bound used by the NIF suite.
fn spawn<T: Send + 'static>(
    work: impl FnOnce() -> T + Send + 'static,
) -> Result<JoinHandle<T>, String> {
    thread::Builder::new()
        .name("rust-std-probe".into())
        .stack_size(128 * 1024)
        .spawn(work)
        .map_err(|error| format!("thread spawn: {error}"))
}

/// Convert unexpected worker unwinding into a check failure after joining it.
fn join<T>(handle: JoinHandle<T>) -> Result<T, String> {
    handle
        .join()
        .map_err(|_| "worker panicked unexpectedly".into())
}

/// A per-thread payload whose destructor proves TLS cleanup completed on join.
struct TlsValue {
    value: String,
    drops: Arc<AtomicUsize>,
}

impl Drop for TlsValue {
    fn drop(&mut self) {
        self.drops.fetch_add(1, Ordering::SeqCst);
    }
}

// Each new worker must start empty; values must never bleed between threads.
thread_local! {
    static TLS: RefCell<Option<TlsValue>> = const { RefCell::new(None) };
}

/// Spawn and join two workers. Each starts with empty TLS; both TLS destructors must run.
pub fn threads() -> Check {
    let drops = Arc::new(AtomicUsize::new(0));
    for value in ["first", "second"] {
        let drops = drops.clone();
        let result = join(spawn(move || {
            TLS.with(|slot| {
                require(
                    slot.borrow().is_none(),
                    "TLS inherited another thread's value",
                )?;
                *slot.borrow_mut() = Some(TlsValue {
                    value: value.into(),
                    drops,
                });
                require(
                    slot.borrow().as_ref().unwrap().value == value,
                    "TLS value changed",
                )
            })
        })?)?;
        result?;
    }
    require(
        drops.load(Ordering::SeqCst) == 2,
        "TLS destructors did not run on join",
    )
}

/// Two threads increment one locked counter 1000 times each; no updates may be lost.
pub fn mutex() -> Check {
    let count = Arc::new(Mutex::new(0usize));
    let worker_count = count.clone();
    let worker = spawn(move || {
        for _ in 0..1000 {
            *worker_count.lock().unwrap() += 1;
        }
    })?;
    for _ in 0..1000 {
        *count.lock().unwrap() += 1;
    }
    join(worker)?;
    let value = *count.lock().map_err(|error| error.to_string())?;
    require(value == 2000, "mutex lost an update")
}

/// Read during a possible writer race, then require the final value after join.
pub fn rwlock() -> Check {
    let value = Arc::new(RwLock::new(19));
    let worker_value = value.clone();
    let worker = spawn(move || *worker_value.write().unwrap() += 23)?;
    let first = *value.read().map_err(|error| error.to_string())?;
    join(worker)?;
    let last = *value.read().map_err(|error| error.to_string())?;
    require(
        (first == 19 || first == 42) && last == 42,
        "rwlock value mismatch",
    )
}

/// Wait with a two-second bound and require notification from the other thread.
pub fn condvar() -> Check {
    let pair = Arc::new((Mutex::new(false), Condvar::new()));
    let worker_pair = pair.clone();
    let (ready, started) = mpsc::channel();
    let worker = spawn(move || -> Check {
        let (lock, wake) = &*worker_pair;
        let guard = lock.lock().map_err(|error| error.to_string())?;
        ready.send(()).map_err(|error| error.to_string())?;
        let (guard, _) = wake
            .wait_timeout_while(guard, Duration::from_secs(2), |ready| !*ready)
            .map_err(|error| error.to_string())?;
        require(*guard, "condvar notification timed out")
    })?;
    let ready = started.recv_timeout(Duration::from_secs(2));
    if ready.is_ok() {
        let (lock, wake) = &*pair;
        *lock.lock().map_err(|error| error.to_string())? = true;
        wake.notify_one();
    }
    let result = join(worker)?;
    ready.map_err(|error| error.to_string())?;
    result
}

/// Receive ordered worker values through a channel with bounded waits, then join.
pub fn channels() -> Check {
    let (send, receive) = mpsc::channel();
    let worker = spawn(move || -> Check {
        send.send(19).map_err(|error| error.to_string())?;
        send.send(23).map_err(|error| error.to_string())
    })?;
    let first = receive.recv_timeout(Duration::from_secs(2));
    let second = receive.recv_timeout(Duration::from_secs(2));
    join(worker)??;
    let first = first.map_err(|error| error.to_string())?;
    let second = second.map_err(|error| error.to_string())?;
    require(
        first == 19 && second == 23,
        "channel value or order mismatch",
    )
}

/// Require monotonic time to advance across sleep and wall time to be after UNIX epoch.
pub fn clock() -> Check {
    let start = Instant::now();
    thread::sleep(Duration::from_millis(10));
    require(
        start.elapsed() >= Duration::from_millis(1),
        "monotonic clock did not advance",
    )?;
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| error.to_string())?;
    Ok(())
}

/// Create an owned scratch directory, exercise read/write/seek/stat/readdir and errno, then clean it.
pub fn file_io(directory: &str) -> Check {
    let directory = Path::new(directory);
    fs::create_dir(directory).map_err(|error| format!("create scratch directory: {error}"))?;
    // Own only the directory just created above; best-effort cleanup also runs on errors.
    struct Scratch<'a>(&'a Path);
    impl Drop for Scratch<'_> {
        fn drop(&mut self) {
            let _ = fs::remove_file(self.0.join("probe.txt"));
            let _ = fs::remove_dir(self.0);
        }
    }
    let _cleanup = Scratch(directory);
    let path = directory.join("probe.txt");
    let check = || -> std::io::Result<()> {
        let mut file = OpenOptions::new()
            .read(true)
            .write(true)
            .create_new(true)
            .open(&path)?;
        file.write_all(b"19 + 23 = 42\n")?;
        file.flush()?;
        file.seek(SeekFrom::Start(0))?;
        let mut contents = String::new();
        file.read_to_string(&mut contents)?;
        if contents != "19 + 23 = 42\n" || file.metadata()?.len() != contents.len() as u64 {
            return Err(std::io::Error::other("file contents or metadata mismatch"));
        }
        let entries = fs::read_dir(directory)?.collect::<Result<Vec<_>, _>>()?;
        if entries.len() != 1
            || entries[0].file_name() != "probe.txt"
            || !entries[0].file_type()?.is_file()
        {
            return Err(std::io::Error::other("directory entry mismatch"));
        }
        let missing = File::open(directory.join("missing"));
        if !matches!(missing, Err(error) if error.kind() == std::io::ErrorKind::NotFound) {
            return Err(std::io::Error::other("errno did not report NotFound"));
        }
        Ok(())
    };
    check().map_err(|error| error.to_string())?;
    fs::remove_file(&path).map_err(|error| error.to_string())?;
    fs::remove_dir(directory).map_err(|error| error.to_string())
}

/// Write and flush stdout and stderr. Console text is expected and announced by Erlang.
pub fn stdio() -> Check {
    let mut stdout = std::io::stdout().lock();
    stdout
        .write_all(b"Rust std stdout probe\n")
        .map_err(|error| error.to_string())?;
    stdout.flush().map_err(|error| error.to_string())?;
    let mut stderr = std::io::stderr().lock();
    stderr
        .write_all(b"Rust std stderr probe\n")
        .map_err(|error| error.to_string())?;
    stderr.flush().map_err(|error| error.to_string())
}

/// Catch a deliberate panic while holding a mutex; require poisoning and successful recovery.
pub fn poison() -> Check {
    let value = Mutex::new(23);
    let caught = std::panic::catch_unwind(|| {
        let _guard = value.lock().unwrap();
        panic!("deliberate panic while holding a mutex");
    });
    require(
        caught.is_err() && value.is_poisoned(),
        "panic did not poison mutex",
    )?;
    let mut guard = value.lock().unwrap_err().into_inner();
    *guard += 19;
    require(*guard == 42, "poisoned mutex could not be recovered")
}

/// Require worker unwinding/destruction, an error from join, and a successful later spawn.
pub fn worker_panic() -> Check {
    struct Guard(Arc<AtomicUsize>);
    impl Drop for Guard {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }
    let drops = Arc::new(AtomicUsize::new(0));
    let worker_drops = drops.clone();
    let worker = spawn(move || {
        let _guard = Guard(worker_drops);
        panic!("deliberate Rust worker panic");
    })?;
    require(worker.join().is_err(), "worker panic did not reach join")?;
    require(
        drops.load(Ordering::SeqCst) == 1,
        "worker panic skipped destructor",
    )?;
    require(
        join(spawn(|| 42)?)? == 42,
        "thread spawn failed after panic",
    )
}

/// Hold locks in another worker: try_lock/try_write must observe contention.
/// Release the owner and join it before reporting a failed assertion.
pub fn contention() -> Check {
    let value = Arc::new(Mutex::new(0));
    let other = value.clone();
    let (ready, started) = mpsc::channel();
    let (release, released) = mpsc::channel();
    let worker = spawn(move || -> Check {
        let mut guard = other.lock().map_err(|error| error.to_string())?;
        ready.send(()).map_err(|error| error.to_string())?;
        released
            .recv_timeout(Duration::from_secs(2))
            .map_err(|error| error.to_string())?;
        *guard = 42;
        Ok(())
    })?;
    let start = started.recv_timeout(Duration::from_secs(2));
    let contended = start.is_ok() && matches!(value.try_lock(), Err(TryLockError::WouldBlock));
    let _ = release.send(());
    join(worker)??;
    start.map_err(|error| error.to_string())?;
    require(
        contended && *value.lock().unwrap() == 42,
        "mutex contention/readback failed",
    )?;

    let value = Arc::new(RwLock::new(19));
    let other = value.clone();
    let (ready, started) = mpsc::channel();
    let (release, released) = mpsc::channel();
    let worker = spawn(move || -> Check {
        let guard = other.read().map_err(|error| error.to_string())?;
        ready.send(()).map_err(|error| error.to_string())?;
        released
            .recv_timeout(Duration::from_secs(2))
            .map_err(|error| error.to_string())?;
        require(*guard == 19, "read guard changed")
    })?;
    let start = started.recv_timeout(Duration::from_secs(2));
    let contended = start.is_ok() && matches!(value.try_write(), Err(TryLockError::WouldBlock));
    let readable = value.try_read().is_ok();
    let _ = release.send(());
    join(worker)??;
    start.map_err(|error| error.to_string())?;
    *value.write().map_err(|error| error.to_string())? += 23;
    require(
        contended && readable && *value.read().unwrap() == 42,
        "rwlock contention/readback failed",
    )
}

/// Exercise actual expiry, distinct from a successful notification with a deadline.
pub fn timeouts() -> Check {
    let lock = Mutex::new(false);
    let wake = Condvar::new();
    let start = Instant::now();
    let (guard, timeout) = wake
        .wait_timeout_while(lock.lock().unwrap(), Duration::from_millis(20), |value| {
            !*value
        })
        .map_err(|error| error.to_string())?;
    require(
        !*guard && timeout.timed_out() && start.elapsed() >= Duration::from_millis(20),
        "condvar did not expire",
    )?;
    let (send, receive) = mpsc::channel::<u8>();
    let start = Instant::now();
    let result = receive.recv_timeout(Duration::from_millis(20));
    require(
        matches!(result, Err(mpsc::RecvTimeoutError::Timeout))
            && start.elapsed() >= Duration::from_millis(20),
        "channel did not expire",
    )?;
    drop(send);
    require(
        matches!(receive.recv(), Err(_)),
        "channel did not report disconnection",
    )
}

/// Start four bounded workers together; join every successfully created worker,
/// including when a later spawn or an individual assertion fails.
fn parallel(check: impl Fn(usize) -> Check + Send + Sync + 'static) -> Check {
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let check = Arc::new(check);
    let mut workers = Vec::new();
    let mut result = (|| -> Check {
        for index in 0..4 {
            let gate = gate.clone();
            let check = check.clone();
            workers.push(spawn(move || {
                let (lock, wake) = &*gate;
                let (guard, _) = wake
                    .wait_timeout_while(lock.lock().unwrap(), Duration::from_secs(2), |open| !*open)
                    .map_err(|error| error.to_string())?;
                require(*guard, "parallel start gate timed out")?;
                drop(guard);
                check(index)
            })?);
        }
        Ok(())
    })();
    *gate.0.lock().unwrap() = true;
    gate.1.notify_all();
    for worker in workers {
        let joined = join(worker).and_then(|result| result);
        if result.is_ok() {
            result = joined;
        }
    }
    result
}

/// All workers race one OnceLock. Its initializer must execute exactly once.
pub fn initialization() -> Check {
    let cell = Arc::new(OnceLock::new());
    let calls = Arc::new(AtomicUsize::new(0));
    let count = calls.clone();
    parallel(move |_| {
        let value = cell.get_or_init(|| {
            count.fetch_add(1, Ordering::SeqCst);
            thread::yield_now();
            42
        });
        require(*value == 42, "OnceLock value mismatch")
    })?;
    require(
        calls.load(Ordering::SeqCst) == 1,
        "OnceLock initialized more than once",
    )
}

/// Force switches with distinct TLS/FP state, aligned allocations and AtomicU64.
/// Expected FP values are computed before workers start, not from their live state.
pub fn context() -> Check {
    // Over-alignment exercises the allocator contract beyond ordinary word alignment.
    #[repr(align(64))]
    struct Aligned([u8; 64]);
    let expected: Vec<Vec<f64>> = (0..4)
        .map(|index| {
            let mut value = index as f64 + 0.25;
            (0..128)
                .map(|_| {
                    value = value * 1.5 + 0.125;
                    value
                })
                .collect()
        })
        .collect();
    let count = Arc::new(AtomicU64::new(0));
    let counter = count.clone();
    let drops = Arc::new(AtomicUsize::new(0));
    let dropped = drops.clone();
    parallel(move |index| {
        let label = format!("context-{index}");
        TLS.with(|slot| {
            *slot.borrow_mut() = Some(TlsValue {
                value: label.clone(),
                drops: dropped.clone(),
            })
        });
        let storage = Box::new(Aligned([index as u8; 64]));
        require(
            (&*storage as *const Aligned as usize) % 64 == 0,
            "allocation is misaligned",
        )?;
        let mut value = std::hint::black_box(index as f64 + 0.25);
        for wanted in &expected[index] {
            value = std::hint::black_box(value * 1.5 + 0.125);
            counter.fetch_add(1, Ordering::SeqCst);
            thread::yield_now();
            require(
                value.to_bits() == wanted.to_bits(),
                "FP state changed across switch",
            )?;
            require(storage.0 == [index as u8; 64], "aligned storage changed")?;
            TLS.with(|slot| {
                require(
                    slot.borrow().as_ref().unwrap().value == label,
                    "TLS changed",
                )
            })?;
        }
        Ok(())
    })?;
    require(
        count.load(Ordering::SeqCst) == 512 && drops.load(Ordering::SeqCst) == 4,
        "atomic updates or TLS destructor count mismatch",
    )
}
