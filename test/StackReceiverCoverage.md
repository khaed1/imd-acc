# Receiver launch regression coverage

Run `forge build` and `forge test` from the repository root. No new dependency or
configuration is required. The new fuzz tests carry 1,000-run settings in their
source; the invariant suite carries 256 runs, depth 64, and fail-on-revert.

`StackReceiverLaunch.t.sol` requires exactly the receiver and the three mainnet
addresses in this assignment. It assembles constructor bytes from `launch.json`
and deploys them through a local CREATE2 factory on an empty chain. Recorded
account accesses check that only one contract is created, the constructor makes
no external calls, and neither existing application is accessed. The existing
`Deployment.t.sol` continues to check runtime size and forbidden opcodes.

`StackReceiverAdversarial.t.sol` covers:

- Separate arrivals, out-of-order execution, replay attempts with other money
  still pending, and preservation of unsolicited IMD.
- Forged payloads, a compose queued by a non-IMD sender, unauthorized direct
  calls, and an overstated list with enough unrelated funds available to steal.
- Truncated headers and ABI arrays, noncanonical addresses, and sum overflow.
- Approval failure, unavailable vault asset lookup, and failure late in a batch
  after another trader's deposit has executed. Reverts preserve balances,
  counters, approvals, hold stamps and the pending queue entry for a retry.
- Arbitrary nonce/source/composeFrom/GUID fields, the maximum OFT shared-decimal
  amount, duplicate traders, one-wei allocations and zero entries.
- A dependency callback that attempts a second, otherwise authenticated compose
  through the endpoint. The nested call is rejected by the reentrancy guard and
  its queued arrival remains deliverable afterward.

`StackReceiverPendingInvariant.t.sol` drives arrivals, execution, rejected calls,
vault pause changes and unsolicited transfers in random order, across six actors
and three source EIDs (Robinhood plus synthetic boundary values). Execution also
injects per-recipient deposit refusals. Its ghost obligations are derived from
the funded input packets, independently of the receiver's counters and events.
After each operation the properties check:

- Receiver IMD equals unconsumed arrivals plus unsolicited transfers.
- Arrived IMD equals pending plus delivered IMD; delivered IMD equals vault
  deposits plus plain payouts.
- Each actor has exactly its expected shares and plain payouts, and the receiver
  holds no shares. No cashback is redirected to the executor.
- Per-source totals equal successful deliveries, sum to `totalDelivered`, and
  remain unchanged by rejected calls and replay attempts.
- Queue commitments still exist for pending messages and consumed entries stay
  consumed. A deterministic scenario verifies both payout branches are reached
  in one batch as well as rejection, replay and out-of-order execution.

The invariant campaign holds the copied vault's exchange rate at its initial
value to make per-actor share expectations independent and exact. The existing
`StackReceiver.t.sol` tests real Solady donation/rounding behavior, preview
failures and zero-share fallback. Pause, approval, transfer and callback fault
injection probe receiver handling; they do not claim the renounced mainnet vault
or real IMD currently exposes those controls or callbacks.

`mocks/QueuedComposeEndpoint.sol` models only the documented compose commitment,
sender namespace, consumption and rollback semantics. Arrival funding is test
scaffolding. It does not model bridge verification or prove the real endpoint's
implementation. The existing `StackReceiverMainnetFork.t.sol` is the live
integration check and skips without `ETH_RPC_URL`. Live Ethereum, Sepolia and
Robinhood fork runs remain owed when their respective RPC URLs are available;
the added suites run entirely offline.
