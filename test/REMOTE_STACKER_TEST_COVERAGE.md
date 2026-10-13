# RemoteStacker adversarial coverage

This addition extends the existing launch, RemoteStacker, audit-regression and multichain
tests. Production contracts, the manifest and Foundry configuration are unchanged.

| Suite | Additional guarantees exercised |
| --- | --- |
| `RemoteStackerAdversarial.t.sol` | False/reverting ERC20 pulls and payments roll back balances, finite allowances and accounting; absent return data is accepted by SafeERC20. A failed tip or a bridge failure after burning also restores the packet, nonce, supply, fees and every recipient's clock. |
| Same suite | Reentrancy is rejected during token pulls, local payments, bridge sends, tip transfers and native refunds. Refund rejection is atomic and exact-fee retries work. |
| Same suite | Recipient registration changes only future contract-wallet credits; registrations are isolated per caller. EIP-7702 delegation and ordinary code route differently. Zero credits, full-supply credits, raw batch limits, step/time boundaries and duplicate recipients are exercised. |
| Same suite | A 1,000-run metamorphic property replays identical state with reordered and duplicated recipients, comparing actual transfers, remaining balances, clocks and decoded delivery events. A separate 1,000-run property exercises both nested entry points at all four token callback stages. |
| `RemoteStackerStateful.t.sol` | Two invariants, checked throughout 256 sequences of 64 handler calls, cover per-recipient custody, project attribution, plain payments, bridge burns, tips and native fees. `afterInvariant` flushes every recipient to check that only sub-step dust remains. |
| `RemoteStackerRefundFork.t.sol` | Two optional tests use live IMD and the endpoint at Robinhood Chain block **87,284,919**: refund callbacks cannot reenter; a refused refund restores the burned tokens and waiting balance, and exact-fee retry succeeds. |

The stateful handler has three projects, two independent flushers, three EOAs, one delegated
EOA and two contract wallets. It interleaves credits (including zero, one wei, bridge-step
boundaries and larger amounts), registrations/clearing, elapsed time, donations, insufficient
allowances, underpaid fees, bridge refusal and duplicate-containing flushes. The deterministic
handler scenario demonstrates that payments, routing changes, failures, tips and donations
are reachable; expected failures are checked explicitly, with `fail-on-revert` enabled.

Ghost credits come from successful call inputs and separately tracked wallet registrations.
Deliveries come from actual OFT packets. Neither is assigned from `waiting` or `totalQueued`.
Each recipient's credits must equal its waiting balance plus delivered IMD plus tips. The
token balance must equal the sum waiting **plus donations**; unsolicited transfers must not
create points or another recipient's entitlement. Every flusher's actual balances must match
its tips and fees. Credit assertions additionally constrain elapsed token-seconds, so fresh
cashback cannot inherit old age and clock rounding cannot lose more than one second.

`RemoteAdversarialOFT` is a test-only fault injector, not an alternative supported production
asset. Its normal mode burns exact shared-decimal amounts and refunds native excess. Its
callback and ERC20 return modes exercise defensive boundaries; they do not assert that live
IMD has callbacks, transfer taxes or rebasing. The existing end-to-end suite covers Ethereum
delivery and vault deposits; these additions concentrate on the source-chain contract.

Run `forge build` and `forge test` without RPC variables for offline verification. Configure
`ROBINHOOD_RPC_URL` to include the optional fork tests; when absent they skip cleanly. No test
changes process environment variables, requires FFI or installs dependencies. Public RPC
reference: <https://robinhood-rpc.publicnode.com>.

Validation for this addition: build passed; full offline suite **322 passed, 0 failed,
28 skipped (350 total)**. Both new pinned-block refund tests and all five existing Robinhood
fork tests passed against the configured provider. The available Ethereum/Robinhood fork
run passed **18 tests**, with six Sepolia tests skipped because no Sepolia RPC was configured.
No new implementation defect was reproduced.
