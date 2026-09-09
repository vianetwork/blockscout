# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Indexer.Fetcher.ZkSync.Utils.ViaExecutionTest do
  use ExUnit.Case, async: true

  alias Indexer.Fetcher.ZkSync.Utils.Rpc

  @marker "0x" <> String.duplicate("1", 64)
  @real_hash "0x" <> String.duplicate("37", 32)
  @time ~U[2026-09-06 21:46:39.587940Z]
  @epoch ~U[1970-01-01 00:00:00Z]
  @details %{"timestamp" => 1, "executeTxHash" => @marker, "executedAt" => "2026-09-06T21:46:39.587940Z"}

  test "unaccepted marker and empty execution data produce zero hash, epoch and no batch-local time" do
    for overrides <- [
          %{},
          %{"viaIsFinalized" => nil},
          %{"viaIsFinalized" => false},
          %{"viaIsFinalized" => "true"},
          %{"viaIsFinalized" => true, "executedAt" => nil},
          %{"viaIsFinalized" => true, "executedAt" => "not-a-timestamp"},
          %{"viaIsFinalized" => true, "executedAt" => "1970-01-01T00:00:00Z"},
          %{"viaIsFinalized" => true, "executedAt" => "1970-01-01T00:00:00.000000Z"},
          %{"executeTxHash" => nil, "executedAt" => nil},
          %{"executeTxHash" => "0x" <> String.duplicate("0", 64), "executedAt" => nil}
        ] do
      batch = @details |> Map.merge(overrides) |> Rpc.transform_batch_details_to_map()
      assert batch.executed_transaction_hash == <<0::256>>, inspect(overrides)
      assert batch.executed_timestamp == @epoch, inspect(overrides)
      assert batch.via_executed_at == nil, inspect(overrides)
    end
  end

  test "nonbinary marker execution times are rejected before ISO8601 parsing" do
    for timestamp <- [123, true, %{}, [], [123]], verdict <- [true, false, nil, "true"] do
      batch =
        @details
        |> Map.merge(%{"viaIsFinalized" => verdict, "executedAt" => timestamp})
        |> Rpc.transform_batch_details_to_map()

      assert batch.executed_transaction_hash == <<0::256>>
      assert batch.executed_timestamp == @epoch
      assert batch.via_executed_at == nil
    end
  end

  test "nonbinary genuine execution and commit/prove times retain upstream parser errors" do
    for {field, hash} <- [{"executedAt", @real_hash}, {"committedAt", @marker}, {"provenAt", @marker}],
        timestamp <- [123, true, %{}, []] do
      details = Map.merge(@details, %{"executeTxHash" => hash, "viaIsFinalized" => true, field => timestamp})

      assert_raise FunctionClauseError, fn -> Rpc.transform_batch_details_to_map(details) end
    end
  end

  test "accepted marker retains its authoritative batch-local time" do
    batch = @details |> Map.put("viaIsFinalized", true) |> Rpc.transform_batch_details_to_map()
    assert batch.executed_transaction_hash == :binary.copy(<<0x11>>, 32)
    assert batch.executed_timestamp == @time
    assert batch.via_executed_at == @time
  end

  test "real execution without a verdict keeps upstream timestamp and missing-time fallback" do
    for {timestamp, expected} <- [{"2026-09-06T21:46:39.587940Z", @time}, {nil, @epoch}] do
      batch =
        @details
        |> Map.merge(%{"executeTxHash" => @real_hash, "executedAt" => timestamp})
        |> Rpc.transform_batch_details_to_map()

      assert batch.executed_transaction_hash == :binary.copy(<<0x37>>, 32)
      assert batch.executed_timestamp == expected
      assert batch.via_executed_at == nil
    end
  end
end
