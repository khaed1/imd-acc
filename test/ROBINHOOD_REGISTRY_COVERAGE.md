# Robinhood registry: additional custody and failure coverage

These tests extend the accepted suite and leave the implementation, launch manifest,
dependencies and Foundry configuration unchanged. They run offline on chain ID 4663,
with the 20 IMD bond, seven-day cooldown, live RemoteStacker address and independent
ArbSys block height. The token, Intake and signing key are local test doubles; they
do not replace deployment arguments or claim to reproduce live state.

| File | Added coverage |
| --- | --- |
| `RegistryRobinhoodBondInvariant.t.sol` | Random sequences across three projects and five actors, including refused payouts, accumulated debts, successful and failed redirected claims, donations, fee changes, retired actions, signed results, failures, lost callbacks, expiry, handoffs and old callbacks. |
| `RegistryRobinhoodExternalCalls.t.sol` | Reentry during the fee pull, fee approval, defended-bond transfer and a creditor's debt claim; unrelated bond isolation; empty ERC-20 transfer return data at settlement and claim; ECDSA signatures when the signer address has code, including wrong-key rejection. |

The invariant has 256 runs of depth 64, with unexpected handler reverts treated as
failures. Its starting state includes two pending challenge bonds and one unpaid
bond, so custody checks cannot pass by never reaching the value-bearing paths.
Expected balances and obligations are updated from the requested actions, signed
outcomes and configured token restrictions, independently of observed payouts.

After every call it checks these properties:

- Registry tokens equal open challenge bonds plus debts plus unsolicited donations.
- Bonds posted equal bonds paid plus open bonds plus debts. Oracle fees never consume
  existing bond backing, and neither failure nor expiry refunds an oracle fee.
- Every actor has exactly their expected token balance and debt entitlement. A new
  beneficiary does not inherit a previous beneficiary's unpaid bond.
- Intake receives only the current question price, consumes its exact allowance,
  and cannot retain approval to withdraw a bond.
- Each request belongs to its own project until closed; closed requests remain
  closed. Only successful signed results consume oracle UUIDs and change listing
  periods. Rollup heights, challenge cooldowns and handoff clocks match the history.

After each campaign, all remaining questions are expired, recipients are unblocked,
and all debts are claimed. Only donations may remain in the registry. Deterministic
scenarios additionally force repeated debts to the same creditor, both token refusal
modes, cross-project claims, each settlement outcome and fee retirement. Valid
oracle callbacks must succeed within 200,000 gas; callback failures are intentional
only for the explicitly starved or expired cases.

The existing suite supplies the manifest/empty-chain deployment rehearsal, panel-rule
JSON limits, ownership gate, canonical protocol signature vector, invalid callback
fields and senders, clock boundaries, self-beneficiary rejection, and cold Robinhood
listing/delisting callbacks. These are retained rather than duplicated.

Accepted limits from the assignment remain accepted: a beneficiary can hold its
project's question slot through paid self-challenges, without renewing the cooldown;
a stranger can occupy an ownerless project's application slot for a fee per round;
and the signer, Intake, action and panel constants are fixed for life. These tests
do not treat those limits as defects or introduce administrative controls.

Run from the repository root:

```sh
forge build --offline --out test/scratch/out --cache-path test/scratch/cache
forge test --offline --out test/scratch/out --cache-path test/scratch/cache
```

The output flags only keep generated artifacts in scratch; ordinary `forge test`
uses the same tests and inline run settings. No delivered test imports scratch,
uses FFI, writes environment variables, downloads dependencies or requires an RPC.
Existing optional fork tests skip without their RPC configuration. Live dependency
state, deployed bytecode equality with Ethereum, and actual off-chain panel decisions
are not established by this offline suite and still require live verification.
