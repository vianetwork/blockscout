# SPDX-License-Identifier: LicenseRef-Blockscout
if Application.get_env(:explorer, :chain_type) == :zksync do
  defmodule Indexer.Fetcher.ZkSync.StatusTrackingTest do
    use EthereumJSONRPC.Case, async: false
    use Explorer.DataCase

    import Mox

    alias Explorer.Chain.Hash.Full, as: FullHash
    alias Explorer.Chain.Wei
    alias Explorer.Chain.ZkSync.{LifecycleTransaction, TransactionBatch}
    alias Indexer.Fetcher.ZkSync.StatusTracking.{Committed, Executed, Proven}

    @tracker_config Indexer.Fetcher.ZkSync.BatchesStatusTracker
    @timestamp ~U[2024-01-01 00:00:00Z]
    @root_hash "0x" <> String.duplicate("aa", 32)
    @commit_transaction_hash "0x" <> String.duplicate("11", 32)
    @prove_transaction_hash "0x" <> String.duplicate("22", 32)
    @execute_transaction_hash "0x" <> String.duplicate("33", 32)

    @block_commit_event "0x8f2916b2f2d78cc5890ead36c06c0f6d5d112c7e103589947e8e2f0d6eddb763"
    @block_execution_event "0x2402307311a4d6604e4e7b4c8a15a7e1213edb39c16a31efa70afb06030d3165"

    setup :set_mox_global
    setup :verify_on_exit!

    setup %{json_rpc_named_arguments: json_rpc_named_arguments} do
      mocked_json_rpc_named_arguments = Keyword.put(json_rpc_named_arguments, :transport, EthereumJSONRPC.Mox)

      %{json_rpc_named_arguments: mocked_json_rpc_named_arguments}
    end

    test "committed settlement uses only the expected L2 batch and skips L1 RPC", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      run_enabled_scenario(Committed, :commit_transaction, :commit_id, json_rpc_named_arguments)
    end

    test "proven settlement uses only the expected L2 batch and skips L1 RPC", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      run_enabled_scenario(Proven, :prove_transaction, :prove_id, json_rpc_named_arguments)
    end

    test "executed settlement uses only the expected L2 batch and skips L1 RPC", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      run_enabled_scenario(Executed, :execute_transaction, :execute_id, json_rpc_named_arguments)
    end

    test "committed settlement expands all batches from the L1 receipt", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      run_expanded_scenario(Committed, :commit_transaction, :commit_id, json_rpc_named_arguments)
    end

    test "proven settlement expands all batches from the L1 calldata", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      run_expanded_scenario(Proven, :prove_transaction, :prove_id, json_rpc_named_arguments)
    end

    test "executed settlement expands all batches from the L1 receipt", %{
      json_rpc_named_arguments: json_rpc_named_arguments
    } do
      run_expanded_scenario(Executed, :execute_transaction, :execute_id, json_rpc_named_arguments)
    end

    defp run_enabled_scenario(tracker, transaction_type, association_key, json_rpc_named_arguments) do
      put_settle_from_l2_only(true)
      expected_batch_number = 1000
      other_batch_number = expected_batch_number + 1

      insert_batch(expected_batch_number)
      insert_batch(other_batch_number)
      expect_l2_batch_details(expected_batch_number)

      assert :ok =
               tracker.look_for_batches_and_update(%{
                 json_l1_rpc_named_arguments: json_rpc_named_arguments,
                 json_l2_rpc_named_arguments: json_rpc_named_arguments
               })

      lifecycle_transaction =
        Repo.get_by!(LifecycleTransaction, hash: transaction_hash(transaction_type))

      assert Repo.get!(TransactionBatch, expected_batch_number) |> Map.fetch!(association_key) ==
               lifecycle_transaction.id

      assert Repo.get!(TransactionBatch, other_batch_number) |> Map.fetch!(association_key) == nil
      assert Repo.aggregate(LifecycleTransaction, :count) == 1
    end

    defp run_expanded_scenario(tracker, transaction_type, association_key, json_rpc_named_arguments) do
      put_settle_from_l2_only(false)
      expected_batch_number = 1000
      other_batch_number = expected_batch_number + 1

      insert_batch(expected_batch_number)
      insert_batch(other_batch_number)
      expect_l2_batch_details(expected_batch_number)
      expect_l1_settlement_call(transaction_type, expected_batch_number, other_batch_number)

      assert :ok =
               tracker.look_for_batches_and_update(%{
                 json_l1_rpc_named_arguments: json_rpc_named_arguments,
                 json_l2_rpc_named_arguments: json_rpc_named_arguments
               })

      lifecycle_transaction =
        Repo.get_by!(LifecycleTransaction, hash: transaction_hash(transaction_type))

      assert Repo.get!(TransactionBatch, expected_batch_number) |> Map.fetch!(association_key) ==
               lifecycle_transaction.id

      assert Repo.get!(TransactionBatch, other_batch_number) |> Map.fetch!(association_key) ==
               lifecycle_transaction.id

      assert Repo.aggregate(LifecycleTransaction, :count) == 1
    end

    defp put_settle_from_l2_only(value) do
      initial_config = Application.get_env(:indexer, @tracker_config, [])
      Application.put_env(:indexer, @tracker_config, Keyword.put(initial_config, :settle_from_l2_only, value))
      on_exit(fn -> Application.put_env(:indexer, @tracker_config, initial_config) end)
    end

    defp insert_batch(number) do
      %TransactionBatch{}
      |> TransactionBatch.changeset(%{
        number: number,
        timestamp: @timestamp,
        l1_transaction_count: 1,
        l2_transaction_count: 1,
        root_hash: @root_hash,
        l1_gas_price: Wei.from(Decimal.new(1), :wei),
        l2_fair_gas_price: Wei.from(Decimal.new(1), :wei),
        start_block: number,
        end_block: number
      })
      |> Repo.insert!()
    end

    defp expect_l2_batch_details(batch_number) do
      expect(EthereumJSONRPC.Mox, :json_rpc, fn
        %{method: "zks_getL1BatchDetails", params: [^batch_number]}, _options ->
          {:ok,
           %{
             "number" => batch_number,
             "timestamp" => 1,
             "l1TxCount" => 1,
             "l2TxCount" => 1,
             "rootHash" => @root_hash,
             "commitTxHash" => @commit_transaction_hash,
             "committedAt" => "2024-01-01T00:00:00Z",
             "proveTxHash" => @prove_transaction_hash,
             "provenAt" => "2024-01-01T00:00:00Z",
             "executeTxHash" => @execute_transaction_hash,
             "executedAt" => "2024-01-01T00:00:00Z",
             "l1GasPrice" => 1,
             "l2FairGasPrice" => 1
           }}
      end)
    end

    defp expect_l1_settlement_call(transaction_type, expected_batch_number, other_batch_number) do
      {method, response} =
        case transaction_type do
          :prove_transaction ->
            calldata =
              "0xe12a6137" <>
                (ABI.TypeEncoder.encode(
                   [1, expected_batch_number, other_batch_number, <<>>],
                   [{:uint, 256}, {:uint, 256}, {:uint, 256}, :bytes]
                 )
                 |> Base.encode16(case: :lower))

            {"eth_getTransactionByHash", %{"input" => calldata}}

          :commit_transaction ->
            {
              "eth_getTransactionReceipt",
              %{
                "logs" => settlement_logs(@block_commit_event, expected_batch_number, other_batch_number)
              }
            }

          :execute_transaction ->
            {
              "eth_getTransactionReceipt",
              %{
                "logs" => settlement_logs(@block_execution_event, expected_batch_number, other_batch_number)
              }
            }
        end

      expect(EthereumJSONRPC.Mox, :json_rpc, fn %{method: ^method}, _options -> {:ok, response} end)
    end

    defp settlement_logs(topic, expected_batch_number, other_batch_number) do
      [expected_batch_number, other_batch_number]
      |> Enum.map(fn batch_number ->
        %{"topics" => [topic, EthereumJSONRPC.integer_to_quantity(batch_number)]}
      end)
    end

    defp transaction_hash(:commit_transaction) do
      {:ok, hash} = FullHash.cast(@commit_transaction_hash)
      hash
    end

    defp transaction_hash(:prove_transaction) do
      {:ok, hash} = FullHash.cast(@prove_transaction_hash)
      hash
    end

    defp transaction_hash(:execute_transaction) do
      {:ok, hash} = FullHash.cast(@execute_transaction_hash)
      hash
    end
  end
end
