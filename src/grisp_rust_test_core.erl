%% @doc Core conversions, checked arithmetic and allocation; no intentional output.
-module(grisp_rust_test_core).
-export([cases/0, run/2]).

%% Declarative names/titles/output kinds consumed by the common runner.
cases() ->
    [{arithmetic, "checked integers and list decoding", quiet},
     {binaries, "binary allocation, byte order and empty input", quiet},
     {bad_arguments, "badarg and overflow remain Erlang exceptions", quiet},
     {allocation, "Vec allocation and std mutex", quiet},
     {numeric_edges, "full-width integers, pointer limits and float roundtrips", quiet}].

%% Each clause asserts a conversion/allocation contract; mismatches become case failures.
run(arithmetic, _) ->
    42 = grisp_rust_testsuite_nifs:add(19, 23),
    42 = grisp_rust_testsuite_nifs:sum([1, 2, 3, 36]),
    0 = grisp_rust_testsuite_nifs:sum([]), ok;
run(binaries, _) ->
    <<3, 2, 1, 0>> = grisp_rust_testsuite_nifs:reverse_binary(<<0, 1, 2, 3>>),
    <<>> = grisp_rust_testsuite_nifs:reverse_binary(<<>>), ok;
run(bad_arguments, _) ->
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:add(not_an_integer, 1) end),
    expect(overflow, fun() -> grisp_rust_testsuite_nifs:add(16#7fffffffffffffff, 1) end),
    expect(overflow, fun() -> grisp_rust_testsuite_nifs:sum([16#7fffffffffffffff, 1]) end);
run(allocation, _) -> true = grisp_rust_testsuite_nifs:allocation(), ok;
run(numeric_edges, _) ->
    case checked_integer_support() of
        ok -> numeric_edges();
        {skip, _} = Skip -> Skip
    end.

%% Stock Rustler 0.39 truncates narrow integers. Skip only that known host build;
%% a patched host runs the assertions, and a missing SDK patch remains a failure.
checked_integer_support() ->
    try grisp_rust_testsuite_nifs:numeric_narrow(-129, 0, 0, 0) of
        {127, 0, 0, 0} ->
            case {grisp_rust_testsuite_nifs:build_versions(),
                  grisp_rust_testsuite_nifs:normal_scheduler_priority()} of
                {#{rustler := <<"0.39.0">>}, {error, <<"rtems_only">>}} ->
                    {skip, stock_rustler_0_39_missing_checked_integer_patch};
                _ -> error({expected_exception, badarg})
            end;
        _ -> error({expected_exception, badarg})
    catch error:badarg -> ok end.

%% Derive usize bounds from this BEAM, so host64 and target32 test their own ABI.
numeric_edges() ->
    WordMax = (1 bsl (8 * erlang:system_info(wordsize))) - 1,
    Signed = -16#8000000000000000,
    Unsigned = 16#ffffffffffffffff,
    Expected = {Signed, Unsigned, WordMax, -1.25},
    Expected = grisp_rust_testsuite_nifs:numeric_edges(Signed, Unsigned, WordMax, -1.25),
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:numeric_edges(Signed - 1, 0, 0, 0.0) end),
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:numeric_edges(0, Unsigned + 1, 0, 0.0) end),
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:numeric_edges(0, -1, 0, 0.0) end),
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:numeric_edges(0, 0, WordMax + 1, 0.0) end),
    {-128, 255, -32768, 65535} = grisp_rust_testsuite_nifs:numeric_narrow(-128, 255, -32768, 65535),
    {127, 0, 32767, 0} = grisp_rust_testsuite_nifs:numeric_narrow(127, 0, 32767, 0),
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:numeric_narrow(-129, 0, 0, 0) end),
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:numeric_narrow(128, 0, 0, 0) end),
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:numeric_narrow(0, -1, 0, 0) end),
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:numeric_narrow(0, 256, 0, 0) end),
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:numeric_narrow(0, 0, -32769, 0) end),
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:numeric_narrow(0, 0, 32768, 0) end),
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:numeric_narrow(0, 0, 0, -1) end),
    expect(badarg, fun() -> grisp_rust_testsuite_nifs:numeric_narrow(0, 0, 0, 65536) end).

%% Require the precise Erlang exception, rather than accepting any decoder failure.
expect(Reason, Fun) ->
    try Fun() of _ -> error({expected_exception, Reason})
    catch error:Reason -> ok end.
