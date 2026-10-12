# Panel rules, versions 2 and 3

The rules (`definitions`) the IdentityMD oracle panel reads when it judges a listing. Version 1 is what the deployed Sepolia ProjectRegistry sends; it is fixed in that contract's code. Version 2 says the same things more plainly, after PLEA's two Sepolia applications split the panel ([history, section 17](history.md#17-registry-trial-pleas-first-applications-2026-10-12)). It was rehearsed once on Sepolia and reached a signed answer ([history, section 18](history.md#18-clearer-panel-rules-rehearsed-2026-10-12)).

**In `src/ProjectRegistry.sol` on `main` since 2026-10-12**, approved by the owner together with IMD's Sepolia fixes, for the mainnet registry. Deployed on Sepolia in test runs 3 and 4 (launches #1371 and #1378); test run 2's registry keeps version 1. A local deployment returns these rules for PLEA's hook character for character as rehearsed.

## The rules

`<project>`, `<rate>` and `<beneficiary>` are filled in by the registry. Each rule must stay at most 512 characters (IMD's limit) and contain no double quote or backslash (the registry writes them into JSON as they are).

| Key | Rule |
|---|---|
| `trading` | `<project>` is a trading venue (for example a Uniswap v4 hook, a pool or a launchpad). Every call it can make to credit(trader, amount) on the Stacker happens while executing a trade, for the trader of that trade, with IMD from the fees of that trade. A wallet, an unverified contract, or a contract that can call credit outside a trade, for wallets it picks, or with IMD that is not from the trade fails this rule. |
| `trader` | The project never chooses who is credited. The trader may be the address the swap caller passes in hookData, as routers do, with the swap sender as the fallback; that address counts as the trader of that trade. |
| `otherPayouts` | Cashback that is not credited through the Stacker is allowed and simply earns no points: for example plain IMD paid when credit reverts, or a payout in another form when crediting is not possible. Such payouts never break the trading or rate rules. |
| `rate` | Each credit is `<rate>` basis points of its trade (100 basis points = 1%), and that rate is between 25 and 100. If the rate can change, the code must keep it between 25 and 100 and `<rate>` must be the rate in force now. |
| `feeGuard` | Split the trading fee into three parts: the cashback; the parts that come back to the owner or team (owner share, treasury, liquidity or reserves the owner or team can withdraw); and the parts that leave for good (burned tokens, prizes paid to others, fees to third parties, locked value as in lockedValue). The parts that leave for good must add up to at least the cashback. If the rate or the fee split can change, the code must keep this true for every allowed setting. |
| `lockedValue` | Liquidity or reserves that no owner or team wallet can ever withdraw count as leaving for good, even if the contract itself can move them between its own positions or pools. |
| `beneficiary` | `<beneficiary>` must be the owner of `<project>`, or a wallet its verified source or its official website names as its team or treasury. (unchanged) |
| `evidence` | Use the verified source published for this address on the chain named in the question, on its block explorer (Etherscan or Blockscout) or on Sourcify; a full or partial match on any one of them is verified source. Use on-chain reads at the latest block. Code with no verified source on any of them, or unreadable code, means false. |

For a challenge, `rate` keeps version 1's challenge form (the rate in force must be within 25-100; the application rate is historical), with the same `otherPayouts` rule.

## What changed from version 1, and why

| Version 1 said | Panel members read it as | Version 2 |
|---|---|---|
| "calls credit … only while executing a trade, for the trader of that trade" | every cashback must be staked, so a plain-IMD fallback (our integration rule 2) or another payout fails | `otherPayouts`: allowed, earns no points |
| "for the trader of that trade" | an address from caller-supplied `hookData` (our integration rule 3) isn't bound to the trader | `trader`: the hookData address counts as the trader |
| "liquidity locked forever" | liquidity the contract can move back into its own reserve isn't locked | `lockedValue`: what no owner or team wallet can ever withdraw leaves for good |
| "the verified source on the block explorer" | Etherscan only; unverified there means false | `evidence`: Etherscan, Blockscout or Sourcify |
| (mainnet condition agreed on 2026-10-11) | | `feeGuard`: true for every allowed setting |

## Results on PLEA's hook (Sepolia, the same question otherwise)

| Rules | Yes | No | Outcome |
|---|---|---|---|
| Version 1, PLEA's first application | 8 | 5 | split, cleared |
| Version 1, PLEA's second application | 9 | 4 | split, cleared |
| Version 2, rehearsal | 11 | 2 | **signed yes** (11 needed) |
| Version 2, test run 4 registry, live application | 11 | 1 | **signed yes: listed** ([history, section 29](history.md#29-live-listing-trial-on-the-test-run-4-registry-plea-listed-and-defended-2026-10-12)) |
| Version 2 (challenge form), live challenge | 11 | 0 | **signed yes: defended** |

With version 2 no member raised the trading, trader, rate or evidence rules. The two "no" answers were about PLEA's own fee split: its owner can enter and win Seasons prizes, and a public `rebalance()` pays a 0.01 IMD keeper tip from the hook's retained IMD to whoever calls it. The margin was exactly the quorum, so one rehearsal is not proof that every panel will agree. The live application on test run 4 again reached exactly 11 yes; its one no was the same keeper tip. The live challenge was unanimous (11 of 11).

## Version 3 (draft for the mainnet registry, 2026-10-12)

Two rules change, both from IMD's audit of the mainnet Stacker launch (#1409, [history section 33](history.md#33-mainnet-stacker-live-launch-1409-2026-10-12)), with the owner's approval; the other six stay as in version 2. Wording as IMD's builder wrote it and its judge accepted; each under 512 characters (473 and 408). Not rehearsed with a panel yet: the next Sepolia run's live trial does that.

| Key | Rule |
|---|---|
| `trader` | The project never chooses who is credited. Resolve valid router hookData first, else IMsgSender(sender).msgSender() during the swap, else sender only if sender has no code; never tx.origin. Reject zero, Stacker, IMD, vault and forwarding-router recipients. If data is invalid, pay plain IMD to a valid resolved caller. If credit fails, pay its resolved trader plain IMD. Never pay an unresolved router: unsupported routes must supply trader data before cashback is enabled. |
| `feeGuard` | Split each trading fee into cashback, owner/team returns (including withdrawable reserves), and qualifying outflow (burns, prizes to others, third-party payments, locked value as in lockedValue). Qualifying outflow must be at least the cashback for every allowed setting of rate and fee split. LP fees do not count: the trader may also be the LP. Amounts returned to the trader, owner or team do not qualify. |

| Version 2 said | The gap | Version 3 |
|---|---|---|
| the trader may come from `hookData`, "with the swap sender as the fallback" | in a Uniswap v4 hook the swap sender is usually the router: a swap from the Uniswap app (no `hookData`) would credit the router, whose `sweep` anyone can call, so bots take the cashback and the points land on the router | `hookData`, else the router's `msgSender()`, else `sender` only if it has no code; never pay an unresolved router |
| LP fees could count as leaving for good | a trader who also provides most of the pool's liquidity gets most of the LP fee back, so 1% cashback against a 1% LP fee is nearly free points | LP fees, and anything returned to the trader, owner or team, don't count |

**Effect on PLEA:** its fee split still passes (its 0.75% that leaves is locked liquidity, burns and prizes, not LP fees). Its Sepolia hook takes the trader from `hookData` and requires it for buys, but falls back to `sender` for sells, which version 3 refuses when the sender is a router; its next hook should ask the router's `msgSender()` or skip the cashback instead.

### Results of version 3 on Sepolia test run 5 (2026-10-12)

| Case | Yes | No | Outcome |
|---|---|---|---|
| SelfCredit, application | 0 | 11 | **signed no: rejected** ([history 39](history.md#39-test-run-5-live-trial-selfcredit-rejected-under-version-3-2026-10-12)) |
| TrialVenue, application | 11 | 3 | **signed yes: listed** ([history 40](history.md#40-positive-case-for-test-run-5-mainnet-registry-prepared-job-12-2026-10-12)) |
| TrialVenue, challenge | 11 | 1 | **signed yes: defended** ([history 41](history.md#41-test-run-5-trial-complete-the-trialvenue-defended-a-clearer-trader-rule-drafted-2026-10-12)) |

All four no votes on the venue say the same thing: its `resolveTrader` accepts any contract the router's `msgSender()` reports and rejects only the router itself, so "a second forwarding router could be credited", which they read as breaking "reject … forwarding-router recipients". The venue follows IMD's own reference implementation, and so does PLEA's new hook; a hook cannot tell a smart-contract wallet from another router by its address, so the phrase has no meaning a hook could implement. Both panels reached exactly the quorum.

## Version 3.1 (the `trader` rule made precise, 2026-10-12)

**In `src/ProjectRegistry.sol` on `main` since 2026-10-12, for Sepolia test run 6 and the mainnet registry.** Not looser: the same behaviour, with the undefined phrase replaced by what every compliant hook actually does. Only the middle sentence changes, and the last one is shortened to stay under 512 characters (505). The other seven rules are unchanged. **Rehearsed** with a one-off oracle question on the venue (its live listing body with only this rule replaced, sent straight to the Intake with no callback; [history 42](history.md#42-version-31-rehearsed-11-of-11-and-in-main-2026-10-12)): **11 true, 0 false, a signed yes**, where the same venue under version 3 had drawn 3 and then 1 no votes on this point.

| Key | Rule |
|---|---|
| `trader` | The project never chooses who is credited. Resolve valid router hookData first, else IMsgSender(sender).msgSender() during the swap, else sender only if sender has no code; never tx.origin. Reject zero, Stacker, IMD, vault and the router itself; the address msgSender() reports is a valid trader even when it is a contract. If data is invalid, pay plain IMD to a valid resolved caller. If credit fails, pay its resolved trader plain IMD. Never pay an unresolved router: such routes need trader data first. |

| Version 3 said | Panel members read it as | Version 3.1 |
|---|---|---|
| "Reject zero, Stacker, IMD, vault and forwarding-router recipients" | any contract `msgSender()` returns might be a router, so a hook that accepts one fails | "the router itself" is rejected; "the address msgSender() reports is a valid trader even when it is a contract" (README rule 3 already says smart-contract wallets stay valid when resolved through the router) |

| Rules | Case (test run 5's registry, the TrialVenue) | Yes | No | Outcome |
|---|---|---|---|---|
| Version 3 | application | 11 | 3 | signed yes |
| Version 3 | challenge | 11 | 1 | signed yes |
| Version 3.1 | rehearsal (same question, this rule replaced) | 11 | 0 | **signed yes** |
