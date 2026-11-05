%% @doc Native interface used by all validation categories.
%% Blocking calls are dirty NIFs; async calls return before their worker finishes.
%% Std checks encode Result as {ok,true}/{error,Binary}; resources are opaque terms.
%% See the category modules for assertions and Rust sources for probe implementations.
-module(grisp_rust_testsuite_nifs).
-export([hello/0, module_id/0, add/2, sum/1, reverse_binary/1, allocation/0]).
-export([build_versions/0]).
-export([new_resource/1, new_resource/2, new_drop_counter/0,
         resource_value/1, resource_drop_count/0, resource_drop_count/1]).
-export([panic_probe/0, panic_drop_count/0, threads/0, mutex/0, rwlock/0,
         condvar/0, channels/0, clock/0, file_io/1, stdio/0, poison/0, worker_panic/0]).
-export([async_messages/4, async_status/0, threaded_helper/2]).
-export([dirty_cpu_panic/0, dirty_io_panic/0]).
-export([derived_terms/3]).
-export([contention/0, timeouts/0, initialization/0, context/0, numeric_edges/4,
         numeric_narrow/4, new_gate/0, release_gate/1, hold_resource/4, owned_echo/4, tracked_binary/1,
         watch_process/1, watch_count/1, cancel_watch/1,
         new_socket_state/0, socket_state/1, socket_roundtrip/4,
         dirty_io_scheduler_priority/0, worker_inheritance/0]).
-export([normal_scheduler/0, dirty_cpu_scheduler/0, dirty_io_scheduler/0,
         dirty_cpu_work/3, dirty_io_work/3, normal_scheduler_priority/0,
         dirty_cpu_scheduler_priority/0, realtime_priority_upgrade/0,
         dirty_cpu_yielding_work/3, dirty_work_active/2]).
-export([dependency_answer/0, dependency_id/0, dependency_feature/0,
         dependency_resource/1, dependency_resource_value/1]).
-on_load(init/0).
-include("cargo.hrl").

%% Load the suite crate; these stubs are replaced by its registered NIF table.
init() -> ?load_nif_from_crate("grisp_rust_testsuite_native", 0).
%% Reuse the separate minimal example, preserving the multiple-module check.
hello() -> grisp_rust_nif:hello().
%% Return <<"testsuite">> to identify this registration table.
module_id() -> erlang:nif_error(nif_not_loaded).
%% Return compiler and dependency versions embedded when this NIF was built.
build_versions() -> erlang:nif_error(nif_not_loaded).
%% Checked i64 addition; invalid terms raise badarg, overflow raises overflow.
add(_, _) -> erlang:nif_error(nif_not_loaded).
%% Decode an i64 list into Vec and return its checked sum.
sum(_) -> erlang:nif_error(nif_not_loaded).
%% Allocate a new BEAM binary containing the input bytes in reverse order.
reverse_binary(_) -> erlang:nif_error(nif_not_loaded).
%% Return true after a small Vec allocation and mutex-protected readback.
allocation() -> erlang:nif_error(nif_not_loaded).
%% Create an opaque suite-owned resource holding the supplied u64.
new_resource(_) -> erlang:nif_error(nif_not_loaded).
%% Create the same resource with a case-local destructor counter (Value, Counter).
new_resource(_, _) -> erlang:nif_error(nif_not_loaded).
%% Create an independent counter; holding it does not keep probed resources alive.
new_drop_counter() -> erlang:nif_error(nif_not_loaded).
%% Read a suite resource; a dependency-owned resource must raise badarg.
resource_value(_) -> erlang:nif_error(nif_not_loaded).
%% Read cumulative suite resource drops; exact-lifetime checks use /1.
resource_drop_count() -> erlang:nif_error(nif_not_loaded).
%% Read destruction count for one case-local counter.
resource_drop_count(_) -> erlang:nif_error(nif_not_loaded).
%% Deliberately panic on a normal scheduler; expect nif_panicked and one guard drop.
panic_probe() -> erlang:nif_error(nif_not_loaded).
%% Read cumulative panic-guard drops to verify unwinding, not just exception delivery.
panic_drop_count() -> erlang:nif_error(nif_not_loaded).
%% Join two std workers; require isolated TLS and both TLS destructors.
threads() -> erlang:nif_error(nif_not_loaded).
%% Require two threads to update one locked counter without lost writes.
mutex() -> erlang:nif_error(nif_not_loaded).
%% Require valid read/write visibility before and after joining a writer.
rwlock() -> erlang:nif_error(nif_not_loaded).
%% Require a notified predicate within a bounded Condvar wait.
condvar() -> erlang:nif_error(nif_not_loaded).
%% Receive ordered std channel values and join their sender.
channels() -> erlang:nif_error(nif_not_loaded).
%% Require advancing monotonic time and accessible wall-clock time.
clock() -> erlang:nif_error(nif_not_loaded).
%% Use a fresh Directory for read/write/seek/stat/readdir/NotFound checks, then remove it.
file_io(_) -> erlang:nif_error(nif_not_loaded).
%% Write and flush stdout/stderr; console output is expected.
stdio() -> erlang:nif_error(nif_not_loaded).
%% Catch panic under a mutex, require poisoning, then recover the guarded value.
poison() -> erlang:nif_error(nif_not_loaded).
%% Require worker unwind/destruction, join failure and a later successful spawn.
worker_panic() -> erlang:nif_error(nif_not_loaded).
%% Start bounded events (Pid, Token, Count, DelayMs); return {ok,true} before completion.
async_messages(_, _, _, _) -> erlang:nif_error(nif_not_loaded).
%% Return {ActiveJobs, FailedSends}; send failures are cumulative across cases.
async_status() -> erlang:nif_error(nif_not_loaded).
%% Use Rustler's helper (Token, PanicWorker); receive its result or error asynchronously.
threaded_helper(_, _) -> erlang:nif_error(nif_not_loaded).
%% Return ERTS thread kind 1 for an ordinary NIF callback.
normal_scheduler() -> erlang:nif_error(nif_not_loaded).
%% Return ERTS thread kind 2 when DirtyCpu registration is effective.
dirty_cpu_scheduler() -> erlang:nif_error(nif_not_loaded).
%% Return ERTS thread kind 3 when DirtyIo registration is effective.
dirty_io_scheduler() -> erlang:nif_error(nif_not_loaded).
%% Read {ok,{Policy,Priority}} on the normal scheduler; hosts return {error,<<"rtems_only">>}.
normal_scheduler_priority() -> erlang:nif_error(nif_not_loaded).
%% Read the dirty CPU pthread's POSIX policy and priority without changing them.
dirty_cpu_scheduler_priority() -> erlang:nif_error(nif_not_loaded).
%% Return {ok,{OldPolicy,OldPriority,Min,Max,Low,High}} after worker-only change/restore.
realtime_priority_upgrade() -> erlang:nif_error(nif_not_loaded).
%% Busy work (Observer, Token, Millis); acknowledge entry, return {ok,2}, accept up to 500 ms.
dirty_cpu_work(_, _, _) -> erlang:nif_error(nif_not_loaded).
%% Same CPU protocol with explicit yields, to distinguish starvation from dispatch failure.
dirty_cpu_yielding_work(_, _, _) -> erlang:nif_error(nif_not_loaded).
%% Observe the exact (Kind, Token), with Kind 2=CPU or 3=IO; no waiting or policy changes.
dirty_work_active(_, _) -> erlang:nif_error(nif_not_loaded).
%% Sleeping control (Observer, Token, Millis); return {ok,3}. Does not test CPU fairness.
dirty_io_work(_, _, _) -> erlang:nif_error(nif_not_loaded).
%% Require held locks to reject conflicting acquisitions while allowing shared readers.
contention() -> erlang:nif_error(nif_not_loaded).
%% Require actual Condvar/channel deadline expiry and channel disconnection.
timeouts() -> erlang:nif_error(nif_not_loaded).
%% Race four workers through one OnceLock; require exactly one initializer.
initialization() -> erlang:nif_error(nif_not_loaded).
%% Check FP/TLS/aligned storage across yields, AtomicU64 updates and TLS destruction.
context() -> erlang:nif_error(nif_not_loaded).
%% Roundtrip {i64,u64,usize,f64}; Rustler must reject values outside the target widths.
numeric_edges(_, _, _, _) -> erlang:nif_error(nif_not_loaded).
%% Check small integer bounds even on hosts whose usize already spans u64.
numeric_narrow(_, _, _, _) -> erlang:nif_error(nif_not_loaded).
%% Create a closed release latch for lifetime checks; native waits expire after two seconds.
new_gate() -> erlang:nif_error(nif_not_loaded).
%% Open a latch idempotently and return true, including during case cleanup.
release_gate(_) -> erlang:nif_error(nif_not_loaded).
%% Hold (Resource, Gate, Pid, Token) in Rust; drop before sending rust_resource_done.
hold_resource(_, _, _, _) -> erlang:nif_error(nif_not_loaded).
%% Copy (Term, Gate, Pid, Token) into OwnedEnv and echo only after the gate opens.
owned_echo(_, _, _, _) -> erlang:nif_error(nif_not_loaded).
%% Create a 4096-byte resource-backed binary counted by the supplied DropCounter.
tracked_binary(_) -> erlang:nif_error(nif_not_loaded).
%% Return {Watch,Registered} for a PID; already-dead PIDs must yield false.
watch_process(_) -> erlang:nif_error(nif_not_loaded).
%% Read validated down callbacks; PID/monitor mismatches raise invalid_monitor_callback.
watch_count(_) -> erlang:nif_error(nif_not_loaded).
%% Demonitor the watched PID; return whether ERTS removed the monitor.
cancel_watch(_) -> erlang:nif_error(nif_not_loaded).
%% Allocate a single-use lifecycle witness retained by Erlang through native cleanup.
new_socket_state() -> erlang:nif_error(nif_not_loaded).
%% Return 0=unused/possibly queued, 1=active, 2=retired; only 2 proves completion.
socket_state(_) -> erlang:nif_error(nif_not_loaded).
%% Dirty IO (State, Port, Pid, Token): read/reverse 16 loopback bytes, return {ok,{16,3}}.
socket_roundtrip(_, _, _, _) -> erlang:nif_error(nif_not_loaded).
%% Read the dirty IO pthread's POSIX policy/priority; RTEMS-only like the other readbacks.
dirty_io_scheduler_priority() -> erlang:nif_error(nif_not_loaded).
%% Return {ok,{ParentPolicy,ParentPriority,ChildPolicy,ChildPriority,QuantumUs}}; RTEMS-only.
worker_inheritance() -> erlang:nif_error(nif_not_loaded).
%% Require caught unwind and one guard drop on a dirty CPU stack.
dirty_cpu_panic() -> erlang:nif_error(nif_not_loaded).
%% Require the same caught unwind/destructor contract on a dirty IO stack.
dirty_io_panic() -> erlang:nif_error(nif_not_loaded).
%% Roundtrip a derived map, tuple and tagged enum; malformed shapes/UTF-8 must fail.
derived_terms(_, _, _) -> erlang:nif_error(nif_not_loaded).

%% Forward through the dependency's public API and loader, preserving that build-chain check.
dependency_answer() -> grisp_rust_test_dependency:answer().
dependency_id() -> grisp_rust_test_dependency_nif:module_id().
dependency_feature() -> grisp_rust_test_dependency_nif:feature_enabled().
dependency_resource(Value) -> grisp_rust_test_dependency_nif:new_resource(Value).
dependency_resource_value(Resource) -> grisp_rust_test_dependency_nif:resource_value(Resource).
