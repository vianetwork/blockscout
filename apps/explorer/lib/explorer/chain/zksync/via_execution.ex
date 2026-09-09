# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Chain.ZkSync.ViaExecution do
  @moduledoc """
  Interprets Via's shared execution marker during batch import and API rendering.
  """

  alias Explorer.Chain.Hash

  @marker :binary.copy(<<0x11>>, 32)
  @encoded_marker "0x" <> Base.encode16(@marker, case: :lower)
  @epoch ~U[1970-01-01 00:00:00Z]

  @doc """
  Decodes and normalizes an RPC batch before lifecycle hashes are deduplicated.
  Clears non-string marker timestamps before invoking the supplied decoder once.
  Only a finalized marker with an execution time after the epoch is accepted.
  """
  @spec normalize_rpc(map(), (map() -> map())) :: map()
  def normalize_rpc(rpc_response, decode_batch) do
    batch = rpc_response |> prepare_rpc() |> decode_batch.()

    cond do
      not marker?(batch.executed_transaction_hash) ->
        Map.put(batch, :via_executed_at, nil)

      rpc_response["viaIsFinalized"] == true and DateTime.compare(batch.executed_timestamp, @epoch) == :gt ->
        Map.put(batch, :via_executed_at, batch.executed_timestamp)

      true ->
        Map.merge(batch, %{
          executed_transaction_hash: <<0::256>>,
          executed_timestamp: @epoch,
          via_executed_at: nil
        })
    end
  end

  @doc """
  Returns batch attributes for a status update using the current normalized RPC
  transaction and its assigned database ID. Only execution updates set or clear
  the batch execution time.
  """
  @spec association_update(:commit_id | :prove_id | :execute_id, map()) :: map()
  def association_update(:execute_id, transaction) do
    %{execute_id: transaction.id, via_executed_at: if(marker?(transaction.hash), do: transaction.timestamp)}
  end

  def association_update(association_key, transaction), do: %{association_key => transaction.id}

  @doc """
  Uses the batch time for marker execution, including nil for legacy batches.
  Other lifecycle timestamps come from the transaction.
  """
  @spec timestamp(:commit_transaction | :prove_transaction | :execute_transaction, map(), map()) :: DateTime.t() | nil
  def timestamp(:execute_transaction, transaction, batch) do
    if marker?(transaction.hash), do: batch.via_executed_at, else: transaction.timestamp
  end

  def timestamp(_stage, transaction, _batch), do: transaction.timestamp

  defp prepare_rpc(%{"executeTxHash" => @encoded_marker, "executedAt" => timestamp} = response)
       when not is_binary(timestamp),
       do: Map.put(response, "executedAt", nil)

  defp prepare_rpc(response), do: response

  defp marker?(%Hash{bytes: bytes}), do: marker?(bytes)
  defp marker?(hash), do: hash == @marker
end
