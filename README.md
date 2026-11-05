grisp_rust
==========

A GRiSP application with a small Rust NIF example and an on-device validation
suite for Rust `std`, Rustler and the native build chain. Three NIF modules in
two Erlang applications exercise shared-runtime and dependency registration.

A supervised worker waits five seconds after application startup, then prints
`Hello from a Rust NIF` and starts the smoke suite. This moves the greeting out
of early kernel and driver startup chatter. The suite reports each category,
case, result, duration and a final
summary using plain text suitable for a serial console.

Target builds use a GRiSP2 SDK with Rust support installed by `make rust-support`,
and compatible `rebar3_cargo`, erlang-cargo, `rebar3_grisp`, `grisp_tools` and GRiSP
runtime. The SDK supplies Rust/Cargo/std and the patched Rust dependencies.
Select its directory or Docker image in `grisp.build.toolchain`; the application
does not need Rust tool paths, rustup, or sibling Rustler/inventory checkouts.

Host development
----------------

With a host Rust toolchain and the Erlang dependencies available, compile with:

    rebar3 compile

Build and start the application with GRiSP hardware emulation using:

```sh
rebar3 as local shell
```

The `local` profile adds `grisp_emulation` and loads `config/local.config`.
Plain `rebar3 shell` does not enable emulation and attempts to load the board's
`grisp_hw` NIF. The greeting and smoke suite run automatically after five seconds.

With stock Rustler 0.39.0, `core/numeric_edges` is skipped because it lacks the
checked-integer decoding patch backported into the GRiSP SDK.

Host builds produce shared libraries for the greeting and suite under
`priv/crates/`. The dependency's library is in its Rebar build directory.
`rebar3 as prod compile` selects Cargo's release profile.

Run checks from the Erlang shell:

    grisp_rust_nif:hello().
    grisp_rust_testsuite:run().
    grisp_rust_testsuite:run([core, threading, async]).
    grisp_rust_testsuite:run_case(rustler, nif_panic).

The suite header reports the compiler and dependency versions recorded when its
NIF was compiled. Query them directly with
`grisp_rust_testsuite_nifs:build_versions()`. The libc version describes the Rust
bindings used to build RTEMS std; it is reported as unknown for prebuilt host std.
    grisp_rust_testsuite:cases().

The default `smoke` profile has 44 general checks and three RTEMS-only checks.
On a host, the RTEMS checks are reported as skipped. The expanded stress
profile is explicitly opt-in because it creates thousands of resources and
threads and runs tens of thousands of calls:

    grisp_rust_testsuite:run(stress).
    grisp_rust_testsuite:run(#{profile => stress, stress_iterations => 5000}).
    grisp_rust_testsuite:run(all).

| Category | Checks and expected behavior |
| --- | --- |
| `core` (5) | Checked arithmetic/list decoding, binary bytes, bad arguments/overflow, allocation, full-width integer/float and pointer-limit conversions. |
| `threading` (11) | Spawn/join, TLS/destructors, locks/channels/condvars, forced contention, actual timeout expiry, concurrent OnceLock initialization, FP/TLS/alignment/64-bit atomics across switches, poison and worker panic recovery. |
| `io` (4) | Clocks, owned scratch files and errno, stdout/stderr, and a fragmented loopback socket exchange between Erlang and Rust while a native read is pending. |
| `rustler` (12) | Registration/dependency isolation, resources and binaries through GC, monitors, derived map/tuple/tagged conversions and UTF-8 validation, and caught panics on normal/dirty CPU/dirty IO schedulers. |
| `async` (6) | Ordered worker messages, dead/exiting recipients, threaded-helper result/panic conversion, and a nested term retained in OwnedEnv after its original owner exits. |
| `scheduling` (9) | Callback thread types; RTEMS normal/dirty policies; worker RR inheritance and quantum; progress during busy/yielding CPU and sleeping IO; worker priority raise/restore. |
| `stress` (5) | Call/allocation/resource/thread churn, eight Erlang callers, and repeated mixed CPU/Erlang/async/socket workloads. Iteration option is bounded at 10,000. |

The socket check needs working IPv4 loopback, without an external server. It
delays and fragments a frame, verifies that the Rust callback is still active,
then checks the exact reversed reply. Native connect/read/write timeouts bound
the operation. The separate sleeping dirty IO check validates blocking behavior;
it is expected to pass with either FIFO or round-robin scheduling.

Mixed stress runs five 500 ms CPU jobs by default (two to ten rounds depending
on `stress_iterations`). Each round requires normal Erlang progress sampled
across at least 250 ms of active CPU work, a Rust event received during that
work, and an overlapping real socket exchange. It reports observed heartbeat
gaps and completion counts. The original churn checks retain their default
5000 cycles/resources, 2000 two-thread TLS cycles and 40,000 arithmetic calls.
This exercises interleaving and cleanup; it is not a memory-leak measurement.

Category modules `grisp_rust_test_*` document and select the checks. They all use
`grisp_rust_testsuite_nifs`, including forwarding calls through the dependency's
public Erlang API. Rust probe implementations describe assertions and cleanup.
The simple `grisp_rust_nif` only exports `hello/0`.

`run/1` also accepts an options map, for example:

    grisp_rust_testsuite:run(#{categories => [io], scratch_root => "/tmp",
                             timeout_ms => 10000, report => true}).

The return value is a map containing `passed`, `failed`, `timeout`, `skipped`,
`elapsed_ms`, `profile` and individual `results` with status, detail and timing.
A failed check does not stop subsequent checks. A timeout skips remaining
checks because native work cannot safely be cancelled. Unconfirmed native
cleanup is also reported as a timeout. After a timeout or an
interrupted run, restart the VM before running the suite again. Further calls
return `{error, {previous_case_timeout, Case}}` or
`{error, {previous_run_interrupted, Pid}}`. Runs are serialized; a concurrent
invocation returns `{error, already_running}`.

Configure automatic startup in `config/sys.config`:

    {grisp_rust, [
        {testsuite_autostart, true},
        {testsuite_delay_ms, 5000},
        {testsuite_profile, smoke},
        {testsuite_scratch_root, "/tmp"}
    ]}

Set `testsuite_autostart` to `false` for manual runs. The scratch root must
already exist and be writable; the file probe creates and removes its own
subdirectory. It does not read from console stdin, which belongs to the Erlang
shell. A local shell without that sys.config uses the same startup defaults.

Cases that write to stdout/stderr or deliberately panic are announced and their
output is delimited before the result line. Panic messages are expected even
when caught; the suite does not replace the global Rust panic hook. Other
system logs can still interleave. Per-case Erlang isolation handles recoverable
failures; native aborts, memory corruption or deadlocks can still stop BEAM.
A dirty NIF timeout cannot cancel its native work. Scheduler checks measure
integration behavior, not real-time deadlines. The busy CPU check requires OS
scheduling that lets normal ERTS threads run under CPU load. Equal-priority
FIFO threads on one CPU may require explicit yields; the yielding comparison
and priority diagnostics help identify this. See
[RUST_SUPPORT_HISTORY.md](RUST_SUPPORT_HISTORY.md#820-scheduling-crash-and-suite-review) for
the board findings. Passing these checks does not establish that every Rust
`std` API is supported, or prove the absence of memory leaks.

Target archives
---------------

The target is GRiSP2 with OTP 29.1.2 and the RTEMS 5 SDK. Build the C SDK with
`make install`, then add Rust with `make rust-support` in the
toolchain repository. A Docker image must be built with `RUST_SUPPORT=1`.
The target uses installed std for `armv7-rtems-eabihf`.

GRiSP discovers Rust NIF crates in the project and its Erlang dependencies and
generates one static archive under `_grisp/grisp2/rust/29.1.2/`.
The individual crates declare both `cdylib` and `rlib` output. Host builds use
their shared libraries; the target links their rlibs and std once. Rust NIFs on
other GRiSP platforms are rejected before compilation.

Firmware and deployment
-----------------------

Build the firmware, then deploy to the configured SD card:

    rebar3 grisp build
    rebar3 grisp deploy

Rust changes require `rebar3 grisp build` before deployment because the NIFs are
linked into BEAM. Deploy builds the target archive and checks recorded build
inputs before creating a release or running deploy scripts. It refuses to
deploy a stale BEAM and excludes host NIF shared libraries from the release.
Erlang-only changes can be deployed directly.

The plugin discovers NIFs from Cargo artifact reports and exported entry
points. `grisp_tools` generates the static NIF Makefile fragment, retains
archive constructors and records build inputs in the OTP installation. Cargo
rebuilds changed local dependencies; the resulting archive contributes to the
GRiSP package hash.
