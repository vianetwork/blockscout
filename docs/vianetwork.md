# Via Network on Blockscout (backend)

Via is a ZKsync Era rollup that settles to Bitcoin instead of Ethereum. This
note explains how this backend indexes a Via chain, and why doing so needs
almost no Via-specific code.

## To the indexer, Via is a ZKsync chain

Via is a fork of ZKsync Era, so a Via batch has the same structure as a ZKsync
batch: a batch number, the L2 blocks and transactions it contains, and a
lifecycle of commit, prove, and execute settlement transactions. The Via server
also answers the same `zks_*` JSON-RPC methods that the ZKsync indexer already
calls.

Because the data has the same shape, this backend indexes Via as the **`zksync`
chain type**. The ZKsync schema, indexer, API, and views all apply to Via with
no changes. There is no separate Via chain type, no parallel set of database
tables, and no Via-specific controllers or fetchers. Setting `CHAIN_TYPE=zksync`
and pointing the indexer at a Via server is enough to index a Via chain.

## The one real difference: how settlement is discovered

A rollup batch is not final the moment it is produced. It moves through three
settlement steps on the parent chain: it is committed, then proven, then
executed. For each batch, the explorer records the parent-chain transaction that
performed each step.

Via and ZKsync differ in exactly one place: how the indexer learns which batches
a settlement transaction covers.

On ZKsync, settlement happens on Ethereum, and a single Ethereum transaction can
settle many batches at once. To find out which batches a transaction covered, the
indexer fetches that Ethereum transaction and reads its event logs (for commit
and execute) or decodes its calldata (for prove), then expands the result into
the full list of batch numbers.

On Via, the Via server reports each batch's settlement transactions directly over
the L2 RPC, one batch at a time. The indexer is already asking the server about a
specific batch, so it can take the settlement transaction the server returns and
use it directly. Nothing on the parent chain needs to be fetched, and no logs or
calldata need to be decoded.

This has a useful side effect: a Via instance needs no L1 (parent chain) RPC
endpoint at all, because settlement is never read from a parent chain.

## Where this lives in the code

The behavior above is the only Via-specific logic in this fork, and it sits
behind one environment variable, `INDEXER_ZKSYNC_SETTLE_FROM_L2_ONLY`.

When the flag is set, the committed, proven, and executed status trackers under
`Indexer.Fetcher.ZkSync.StatusTracking` skip the parent-chain expansion and use
the batch number they are already checking. The check itself is
`Indexer.Fetcher.ZkSync.StatusTracking.CommonUtils.settle_from_l2_only?/0`. When
the flag is unset the trackers behave exactly as upstream ZKsync does, so this
change is invisible to a normal ZKsync deployment.

## Running a Via instance

- `CHAIN_TYPE=zksync`
- `INDEXER_ZKSYNC_BATCHES_ENABLED=true`
- `INDEXER_ZKSYNC_SETTLE_FROM_L2_ONLY=true`
- L2 RPC pointed at a Via server, which speaks the ZKsync RPC API
- network name, currency, and logos set through the standard instance
  configuration

No L1 RPC endpoint is required.
