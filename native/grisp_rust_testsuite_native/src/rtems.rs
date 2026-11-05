//! Scheduling probes shared with the standalone RTEMS validation harness.
#[path = "rtems_ffi.rs"]
pub mod ffi;
use ffi::*;

/// Query the calling pthread without altering its policy or priority.
pub fn priority() -> Result<(i32, i32), String> {
    let mut policy = 0;
    let mut param = SchedParam::default();
    // All pointers refer to initialized, correctly sized SDK-compatible storage.
    let status = unsafe { pthread_getschedparam(pthread_self(), &mut policy, &mut param) };
    if status != 0 {
        return Err(format!("pthread_getschedparam returned {status}"));
    }
    Ok((policy, param.sched_priority))
}

/// Read the configured quantum and verify scheduling inherited by a new worker.
pub fn inheritance() -> Result<(i32, i32, i32, i32, u64), String> {
    let parent = priority()?;
    let mut interval = Timespec::default();
    // PID zero queries this process; Timespec uses the measured RTEMS 5/6 ABI.
    if unsafe { sched_rr_get_interval(0, &mut interval) } != 0 {
        return Err(format!(
            "sched_rr_get_interval: {}",
            std::io::Error::last_os_error()
        ));
    }
    if interval.tv_sec < 0 || !(0..1_000_000_000).contains(&interval.tv_nsec) {
        return Err("invalid RR interval".into());
    }
    let micros = (interval.tv_sec as u64)
        .checked_mul(1_000_000)
        .and_then(|value| value.checked_add(interval.tv_nsec as u64 / 1000))
        .filter(|value| *value > 0)
        .ok_or("invalid RR quantum")?;
    let child = std::thread::Builder::new()
        .stack_size(128 * 1024)
        .spawn(priority)
        .map_err(|error| error.to_string())?
        .join()
        .map_err(|_| "inheritance worker panicked")??;
    Ok((parent.0, parent.1, child.0, child.1, micros))
}

/// Raise a std worker by one POSIX priority and restore its original settings.
/// Avoid the old probe's system-wide extremes: minimum then maximum priority.
pub fn priority_upgrade() -> Result<(i32, i32, i32, i32, i32, i32), String> {
    std::thread::Builder::new()
        .name("rust-priority-probe".into())
        .stack_size(128 * 1024)
        .spawn(|| {
            let mut old_policy = 0;
            let mut old = SchedParam::default();
            let thread = unsafe { pthread_self() };
            let status = unsafe { pthread_getschedparam(thread, &mut old_policy, &mut old) };
            if status != 0 {
                return Err(format!("initial pthread_getschedparam returned {status}"));
            }
            let minimum = unsafe { sched_get_priority_min(SCHED_RR) };
            let maximum = unsafe { sched_get_priority_max(SCHED_RR) };
            if minimum < 0 || maximum <= minimum {
                return Err(format!("invalid SCHED_RR priority range {minimum}..={maximum}"));
            }
            let low = old.sched_priority.clamp(minimum, maximum - 1);
            let result = (|| {
                for value in [low, low + 1] {
                    let param = SchedParam { sched_priority: value, ..SchedParam::default() };
                    let status = unsafe { pthread_setschedparam(thread, SCHED_RR, &param) };
                    if status != 0 {
                        return Err(format!("set SCHED_RR priority {value} returned {status}"));
                    }
                    let actual = priority()?;
                    if actual != (SCHED_RR, value) {
                        return Err(format!("priority readback mismatch: expected ({SCHED_RR}, {value}), got {actual:?}"));
                    }
                }
                Ok((old_policy, old.sched_priority, minimum, maximum, low, low + 1))
            })();
            let restored = unsafe { pthread_setschedparam(thread, old_policy, &old) };
            if restored != 0 {
                return Err(format!("restore original policy/priority returned {restored}; probe={result:?}"));
            }
            if priority()? != (old_policy, old.sched_priority) {
                return Err("original policy/priority was not restored".into());
            }
            result
        })
        .map_err(|error| format!("spawn priority probe: {error}"))?
        .join()
        .map_err(|_| "priority probe worker panicked".to_string())?
}
