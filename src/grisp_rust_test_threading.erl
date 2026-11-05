%% @doc Bounded worker/thread cleanup and synchronization. Panic cases emit text.
-module(grisp_rust_test_threading).
-export([cases/0, run/2]).

%% Titles describe the std invariant; panic cases announce intentional native output.
cases() ->
    [{threads, "independent TLS values and destructors after join", quiet},
     {mutex, "2000 updates without lost writes", quiet},
     {rwlock, "read/write visibility after join", quiet},
     {condvar, "notification with a bounded wait", quiet},
     {channels, "ordered worker messages through std channels", quiet},
     {contention, "held mutex/read lock reject conflicting acquisitions", quiet},
     {timeouts, "condvar and channel deadlines actually expire", quiet},
     {initialization, "four workers initialize one OnceLock exactly once", quiet},
     {context, "FP/TLS/alignment and AtomicU64 survive forced switches", quiet},
     {poison, "caught panic poisons a mutex and allows recovery", panic},
     {worker_panic, "worker unwinds, drops values, and later spawn succeeds", panic}].

%% Rust owns thread joins and assertions; {ok,true}/{error,Binary} reach the runner unchanged.
run(Name, _) -> apply(grisp_rust_testsuite_nifs, Name, []).
