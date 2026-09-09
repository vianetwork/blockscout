# SPDX-License-Identifier: LicenseRef-Blockscout
if Application.get_env(:explorer, :chain_type) == :zksync do
  defmodule BlockScoutWeb.ZkSyncViaExecutionTimestampTest do
    use BlockScoutWeb.ConnCase, async: false

    import Mox

    alias BlockScoutWeb.API.V2.ZkSyncView
    alias Explorer.Chain.Hash.Full, as: FullHash
    alias Explorer.Chain.Wei
    alias Explorer.Chain.ZkSync.{BatchBlock, BatchTransaction, LifecycleTransaction, TransactionBatch}
    alias Explorer.Repo
    alias Indexer.Fetcher.ZkSync.BatchesStatusTracker
    alias Indexer.Fetcher.ZkSync.Discovery.Workers
    alias Indexer.Fetcher.ZkSync.StatusTracking.{CommonUtils, Executed}
    alias Indexer.Fetcher.ZkSync.Utils.Db

    @marker "0x" <> String.duplicate("1", 64)
    @real_hash "0x" <> String.duplicate("37", 32)
    @root_hash "0x" <> String.duplicate("ab", 32)
    @time_263 "2026-09-06T21:46:39.587940Z"
    @time_264 "2026-09-08T12:36:09.030913Z"
    @corrected_time "2026-09-08T12:36:09.030914Z"
    @rpc [transport: EthereumJSONRPC.Mox, transport_options: []]
    @tracker %{json_l1_rpc_named_arguments: @rpc, json_l2_rpc_named_arguments: @rpc}
    @discovery %{json_rpc_named_arguments: @rpc, chunk_size: 10}

    setup :set_mox_global
    setup :verify_on_exit!

    setup do
      initial = Application.get_env(:indexer, BatchesStatusTracker, [])
      Application.put_env(:indexer, BatchesStatusTracker, Keyword.merge(initial, settle_from_l2_only: true))
      on_exit(fn -> Application.put_env(:indexer, BatchesStatusTracker, initial) end)
    end

    test "sequential polling reuses the marker ID and preserves batch-local and unknown legacy times" do
      [legacy, first, second] = Enum.map(262..264, &fixture/1)
      Enum.each([legacy, first, second], &insert_batch/1)
      lifecycle = associate_legacy(legacy)

      expect_details(first, %{"executedAt" => @time_263})
      assert :ok = Executed.look_for_batches_and_update(@tracker)
      assert_execution(first, @marker, @time_263)
      assert_execution(second, nil, nil)
      assert Db.get_earliest_unexecuted_batch_number() == 264

      expect_details(second, %{"executedAt" => @time_264})
      assert :ok = Executed.look_for_batches_and_update(@tracker)
      assert_execution(first, @marker, @time_263)
      assert_execution(second, @marker, @time_264)
      assert_execution(legacy, @marker, nil)
      assert Repo.get!(TransactionBatch, 262).via_executed_at == nil
      assert Repo.get!(TransactionBatch, 263).execute_id == lifecycle.id
      assert Repo.get!(TransactionBatch, 264).execute_id == lifecycle.id
      assert Repo.aggregate(LifecycleTransaction, :count) == 1
      assert Db.get_earliest_unexecuted_batch_number() == nil
      assert :ok = Executed.look_for_batches_and_update(@tracker)
    end

    test "a later commit-stage import preserves the accepted execution time" do
      first = fixture(263)
      full_import([{first, %{"executedAt" => @time_263}}])
      expect_details(first, %{"commitTxHash" => @real_hash, "committedAt" => @time_263})

      assert {:look_for_batches, hash, commits} =
               CommonUtils.check_if_batch_status_changed(263, :commit_transaction, @rpc)

      assert :ok = CommonUtils.associate_and_import_or_prepare_for_recovery([263], commits, hash, :commit_id)
      assert_execution(first, @marker, @time_263)
    end

    test "full discovery preserves distinct times through deduplication, correction and replacement" do
      [first, second] = Enum.map(263..264, &fixture/1)
      full_import([{first, %{"executedAt" => @time_263}}, {second, %{"executedAt" => @time_264}}])
      assert_execution(first, @marker, @time_263)
      assert_execution(second, @marker, @time_264)
      assert Repo.get!(TransactionBatch, 263).execute_id == Repo.get!(TransactionBatch, 264).execute_id
      assert Repo.aggregate(LifecycleTransaction, :count) == 1

      # Correct only the timestamp, then repeat the identical full import.
      for _ <- 1..2 do
        full_import([{second, %{"executedAt" => @corrected_time}}])
        assert_execution(first, @marker, @time_263)
        assert_execution(second, @marker, @corrected_time)
      end

      # Full import replaces the execution association and time with the accepted snapshot.
      full_import([{second, %{"viaIsFinalized" => false, "executedAt" => @corrected_time}}])
      assert_execution(first, @marker, @time_263)
      assert_execution(second, nil, nil)
      assert Repo.get!(TransactionBatch, 264).via_executed_at == nil
    end

    test "an absent verdict blocks polling and cannot inherit execution from a full-import neighbour" do
      [first, second] = Enum.map(263..264, &fixture/1)
      Enum.each([first, second], &insert_batch/1)
      expect_details(first, %{"viaIsFinalized" => :absent})
      assert :ok = Executed.look_for_batches_and_update(@tracker)
      assert_execution(first, nil, nil)
      assert_execution(second, nil, nil)
      assert Repo.aggregate(LifecycleTransaction, :count) == 0
      assert Db.get_earliest_unexecuted_batch_number() == 263

      full_import([{first, %{"viaIsFinalized" => :absent}}, {second, %{"executedAt" => @time_264}}])
      assert_execution(first, nil, nil)
      assert_execution(second, @marker, @time_264)
      assert Repo.get!(TransactionBatch, 263).via_executed_at == nil
      assert Db.get_earliest_unexecuted_batch_number() == 263
    end

    test "real execution replacement clears the Via time and keeps genuine shared lifecycle times" do
      [first, second] = Enum.map(263..264, &fixture/1)
      full_import([{first, %{"executedAt" => @time_263}}])
      real = %{"executeTxHash" => @real_hash, "executedAt" => @time_264, "viaIsFinalized" => :absent}
      full_import([{first, real}, {second, real}])
      assert_execution(first, @real_hash, @time_264)
      assert_execution(second, @real_hash, @time_264)
      assert Repo.get!(TransactionBatch, 263).via_executed_at == nil
      assert Repo.get!(TransactionBatch, 264).via_executed_at == nil
    end

    test "batch, transaction, block and batch-list APIs project accepted and legacy times" do
      [legacy, first, second] = Enum.map(262..264, &fixture/1)
      insert_batch(legacy)
      associate_legacy(legacy)
      full_import([{first, %{"executedAt" => @time_263}}, {second, %{"executedAt" => @time_264}}])
      list = build_conn() |> get("/api/v2/zksync/batches") |> json_response(200)

      for {item, time} <- [{legacy, nil}, {first, @time_263}, {second, @time_264}] do
        assert_execution(item, @marker, time)
        assert_fields(Enum.find(list["items"], &(&1["number"] == item.number)), @marker, time)

        for path <- ["/api/v2/transactions/#{item.transaction.hash}", "/api/v2/blocks/#{item.block.hash}"] do
          response = build_conn() |> get(path) |> json_response(200)
          assert_fields(response["zksync"], @marker, time)
        end
      end
    end

    test "unloaded batch and lifecycle associations never use the shared timestamp" do
      transaction = build(:transaction)
      assert ZkSyncView.extend_transaction_json_response(%{}, transaction)["zksync"]["status"] == "Processed on L2"
      assert ZkSyncView.extend_block_json_response(%{}, build(:block))["zksync"]["execute_transaction_timestamp"] == nil
      {:ok, hash} = FullHash.cast(@marker)
      marker = %LifecycleTransaction{hash: hash, timestamp: ~U[2025-09-28 01:16:41.167558Z]}
      transaction = %{transaction | zksync_execute_transaction: marker}

      assert ZkSyncView.extend_transaction_json_response(%{}, transaction)["zksync"]["execute_transaction_timestamp"] ==
               nil
    end

    defp fixture(number) do
      block = insert(:block, number: number * 4)
      %{number: number, block: block, transaction: :transaction |> insert() |> with_block(block, status: :ok)}
    end

    defp insert_batch(item) do
      %TransactionBatch{}
      |> TransactionBatch.changeset(%{
        number: item.number,
        timestamp: ~U[2026-09-01 00:00:00.000000Z],
        l1_transaction_count: 0,
        l2_transaction_count: 1,
        root_hash: @root_hash,
        l1_gas_price: Wei.from(Decimal.new(1), :wei),
        l2_fair_gas_price: Wei.from(Decimal.new(1), :wei),
        start_block: item.block.number,
        end_block: item.block.number
      })
      |> Repo.insert!()

      Repo.insert!(%BatchBlock{batch_number: item.number, hash: item.block.hash})
      Repo.insert!(%BatchTransaction{batch_number: item.number, transaction_hash: item.transaction.hash})
    end

    defp associate_legacy(item) do
      lifecycle =
        %LifecycleTransaction{}
        |> LifecycleTransaction.changeset(%{id: 1, hash: @marker, timestamp: ~U[2025-09-28 01:16:41.167558Z]})
        |> Repo.insert!()

      Repo.get!(TransactionBatch, item.number) |> Ecto.Changeset.change(execute_id: lifecycle.id) |> Repo.update!()
      lifecycle
    end

    defp details(item, overrides) do
      %{
        "number" => item.number,
        "timestamp" => 1_787_788_800,
        "l1TxCount" => 0,
        "l2TxCount" => 1,
        "rootHash" => @root_hash,
        "executeTxHash" => @marker,
        "executedAt" => @time_263,
        "viaIsFinalized" => true,
        "status" => "verified",
        "l1GasPrice" => 1,
        "l2FairGasPrice" => 1
      }
      |> Map.merge(overrides)
      |> Enum.reject(fn {_key, value} -> value == :absent end)
      |> Map.new()
    end

    defp expect_details(item, overrides) do
      number = item.number

      expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: "zks_getL1BatchDetails", params: [^number]}, _ ->
        {:ok, details(item, overrides)}
      end)
    end

    defp full_import(fixtures) do
      by_number = Map.new(fixtures, fn {item, overrides} -> {item.number, {item, overrides}} end)
      by_block = Map.new(fixtures, fn {item, _} -> {item.block.number, item} end)

      expect_batch_call("zks_getL1BatchDetails", fn [number] ->
        {item, overrides} = Map.fetch!(by_number, number)
        details(item, overrides)
      end)

      expect_batch_call("zks_getL1BatchBlockRange", fn [number] ->
        {item, _} = Map.fetch!(by_number, number)
        block = EthereumJSONRPC.integer_to_quantity(item.block.number)
        [block, block]
      end)

      expect_batch_call("eth_getBlockByNumber", fn [number, false] ->
        item = Map.fetch!(by_block, EthereumJSONRPC.quantity_to_integer(number))
        %{"hash" => to_string(item.block.hash), "transactions" => [to_string(item.transaction.hash)]}
      end)

      assert :ok = Workers.get_full_batches_info_and_import(Map.keys(by_number), @discovery)
    end

    defp expect_batch_call(method, result) do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn requests, _ ->
        responses =
          Enum.map(requests, fn %{id: id, method: ^method, params: params} ->
            %{id: id, result: result.(params)}
          end)

        {:ok, Enum.reverse(responses)}
      end)
    end

    defp assert_execution(item, hash, time) do
      response = build_conn() |> get("/api/v2/zksync/batches/#{item.number}") |> json_response(200)
      assert_fields(response, hash, time)
    end

    defp assert_fields(response, hash, time) do
      assert response["execute_transaction_hash"] == hash
      assert response["execute_transaction_timestamp"] == time
      assert response["status"] == if(is_nil(hash), do: "Sealed on L2", else: "Executed on L1")
    end
  end
end
