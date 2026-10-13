# For the PondPad session: imd/acc cashback on Robinhood Chain (2026-10-13)

PondPad's v1 leaves trading rewards out (`launchpad/ARCHITECTURE-v1.md`, section 1, "Not in v1"), so this is for the version that adds them. It says what imd/acc offers on Robinhood Chain, how PondPad's contracts would call it, and what the listing panel will check. Read from PondPad's branch `claude/bold-gauss-qhlw86` at `1a0dc0d`; nothing there was changed.

## 1. What is live on Robinhood Chain (chain 4663)

| Contract | Address | What it does |
|---|---|---|
| RemoteStacker | `0x4de07c2fa46d5d6ed9ceb3f38ec56d3461b3e898` (launch #1537) | `credit(trader, imdAmount)`, the same call as the Stacker on Ethereum. Pulls the IMD from the caller and keeps it waiting for the trader; emits `Queued(project, trader, recipient, imd)`, the points record. |
| ProjectRegistry | `0x814da7f2469e3e37158ab7e031a31b3004d9bca1` (launch #1561) | Decides which projects' credits earn points, through IdentityMD oracle panels (rules version 3.1). |
| IMD | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` | The same LayerZero OFT PondPad pairs every coin with. |
| StackReceiver (Ethereum) | `0x1999a54f573dac75ce8ef62a555dba418c9b3d10` (launch #1529) | Deposits each delivery into the sIMD vault for its trader. |

**The route:** cashback waits in the RemoteStacker until anyone calls `flush(recipients)` (up to 50 traders). The IMD crosses IMD's own bridge and lands in the trader's wallet on Ethereum as sIMD, about two minutes later (tested live twice, imd/acc history 52). The flusher pays the bridge fee (about 0.0007 ETH for a few traders, `quoteFlush` gives it) and earns a tip from each trader flushed: 2% per 12 hours waited, at most 2%. The trader always gets at least 98%, and can flush their own cashback at once from https://imdacc.fun (network switch on Robinhood, Your Stack). **PondPad's keeper bot could add `flush`** to its permissionless calls: it would earn the tips.

**Smart-contract wallets** may not exist at the same address on Ethereum, so a trader with code is paid plain IMD on Robinhood Chain at once (`Paid`, no points) unless it registered an Ethereum address with `setEthereumRecipient`. Plain wallets, including EIP-7702 ones, go through the queue.

## 2. Where PondPad would call it

Every PondPad trade takes its fees on the IMD side, in `BondingCurve` before graduation and in `PadHook` after (ARCHITECTURE-v1 section 4.1), so the cashback is a slice of that IMD:

- in `BondingCurve`, inside the buy and sell that collect the fee;
- in `PadHook`, in `afterSwap`, from the fee on the actual filled amount (as the hook already settles it).

Each contract that calls `credit` is a separate "project" for imd/acc: two listings, each applied for by that contract's `owner()`, unless both route the cashback through one contract.

```solidity
// Once, in the constructor or an owner call: let the RemoteStacker pull IMD.
IERC20(IMD).approve(REMOTE_STACKER, type(uint256).max);

// On each trade, with the real trader resolved (section 3), out of the fee:
uint256 cashback = imdSideAmount * CASHBACK_BPS / 10_000; // 25 to 100 bps
require(gasleft() >= 450_000, "imd/acc: insufficient gas"); // outside try/catch
try IRemoteStacker(REMOTE_STACKER).credit{gas: 300_000}(trader, cashback) {
    // queued for the trader (or paid as plain IMD to a contract wallet)
} catch {
    IERC20(IMD).safeTransfer(trader, cashback); // a trade never reverts because of imd/acc
}
```

**Gas**, measured on a fork of the live RemoteStacker: 109k for a new trader (the first credit), 55k for a repeat one, 89k for a contract wallet paid plain IMD. The 300k forwarded and the 450k check are the live trial venue's settings (`test/trial/RemoteTrialVenue.sol` in khaed1/imd-acc, deployed at `0x81d1…9bcc` and traded). Keep the gas check outside the `try`, so a wallet's estimate can't pick the path without cashback.

## 3. The trader rule: one change needed

ARCHITECTURE-v1 section 4.2 says the hook's events carry "the real trader passed by the router in `hookData`, falling back to `sender`". The panel's rule (version 3.1) refuses that fallback when `sender` is a router, because the cashback would go to the router (anyone can sweep Universal Router's balance). The rule:

1. valid trader data in `hookData` (PadRouter's own encoding);
2. else, during the swap, the router's `msgSender()` (bounded and caught; reject zero, the hook, the RemoteStacker, IMD and the router itself; a contract `msgSender()` reports is a valid trader, a smart wallet);
3. else `sender` only if it has no code;
4. never `tx.origin`; if no trader resolves, skip the cashback without blocking the trade.

On the curve, `BondingCurve` can take the trader from `PadRouter` (PondPad's own router, trusted by address) and use `msg.sender` when a wallet calls the curve directly. PLEA needed the same change; the reference code is `test/TraderResolution.t.sol` and `RemoteTrialVenue.resolveTrader` in khaed1/imd-acc.

## 4. The fee guard: PondPad's split does not pass yet

The panel lists a project only if the part of its fee that **leaves for good** (burned tokens, liquidity locked forever, prizes or fees paid to third parties) is at least the cashback, **at every rate and fee split the code allows**. Parts that can come back to the owner, the team or the trader don't count, so trading with yourself to farm points always costs more than it brings back.

| PondPad fee part (per trade) | Counts as leaving for good? |
|---|---|
| Creator base 0.5% → the coin's fee recipient | No: the trader may be the creator |
| Coin tax 0–3% (creator, holders, swarm budget) | No: it can be 0, and creator and holder shares can come back to the trader |
| Protocol 1% → integrator (15%, referred trades) | No: the trader may run the integrating bot |
| → sPONDPAD stakers (40%, 25–60%) | No: the owner, team or trader may stake |
| → growth (20%) and treasury (15%) | No: team-controlled |
| → IMD workers (25%, 15–35%) | **Not as built:** `WorkerFund`'s `workerRewards` address is set by PondPad's 7-day timelock, so the team could point it at itself. Even with a fixed address, the lowest allowed share is 0.15% of a trade (0.25% × 85% = 0.21% on referred trades at the default), below the 0.25% minimum cashback |

So as designed, nothing in the split counts with certainty, and the panel would answer no. Three ways forward, PondPad's choice:

1. **Recommended: an equal burn, fixed in code.** The crediting contract takes the cashback and the same amount burned (IMD sent to `0x…dEaD`) out of the protocol fee, at a constant rate. This is what the listed trial venue does (0.5% credited, 0.5% burned, listed 11 of 11 on Sepolia and on Robinhood Chain). At the 0.25% minimum it costs half of the 1% protocol fee (0.25% to traders, 0.25% burned), leaving 0.5% for the splitter. Easy for the panel to verify from the source.
2. **The IMD workers' share as the part that leaves:** make the worker address immutable (or bounded to a fixed third party), keep its share at least the cashback at every allowed setting (a floor of 25% of the protocol fee at 0.25% cashback, and the integrator cut taken from another bucket), and fund the cashback from stakers, growth or treasury. Cheaper, but it needs the IMD worker address PondPad is still waiting for, and the panel has to accept that address as a third party.
3. **Use imd/acc unlisted:** traders still get sIMD on Ethereum; their credits earn no points.

## 5. Listing on Robinhood Chain

- The contract's `owner()` (or the contract itself) calls `applyListing(project, name, sourceUrl, rateBps, beneficiary)` on the registry above, after approving the 0.5 IMD fee (Robinhood Chain IMD). If the owner is a timelock behind the team Safe, the application is a governance transaction.
- The source must be verified on chain 4663 (Sourcify or Blockscout: `robinhoodchain.blockscout.com`); the panel reads it and the live state, and the question is filed under chain 4663.
- The beneficiary is the project's owner or a wallet its source or official site names as its team or treasury.
- Points count the `Queued` credits from the listing block on, in Robinhood Chain's own block numbers. Anyone can challenge after 7 days with a 20 IMD bond; a defended challenge pays the bond to the beneficiary.
- Test first on a fork of Robinhood Chain (`anvil --fork-url https://rpc.mainnet.chain.robinhood.com`): imd/acc has no RemoteStacker on a Robinhood testnet. On a fork, a project contract can credit the live RemoteStacker and a flush goes through the real IMD token (khaed1/imd-acc `test/RobinhoodFork.t.sol`).

## 6. What imd/acc's site shows

The website's Robinhood network reads the RemoteStacker and the registry live: each project's credits and status, traders' cashback queued, waiting and delivered, and points. PondPad is not mentioned on the site until it integrates.
