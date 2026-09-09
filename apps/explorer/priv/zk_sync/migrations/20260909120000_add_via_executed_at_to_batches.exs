# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Repo.ZkSync.Migrations.AddViaExecutedAtToBatches do
  use Ecto.Migration

  def change do
    # The shared synthetic lifecycle timestamp is not authoritative for any individual batch.
    # Leave existing rows NULL.
    alter table(:zksync_transaction_batches) do
      add(:via_executed_at, :utc_datetime_usec, null: true)
    end
  end
end
