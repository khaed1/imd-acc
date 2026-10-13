# Site check

Browser checks for the imd/acc Sepolia test site (test run 2). Not part of the contracts; nothing here is deployed.

- **Reads** come from live Sepolia, or from a local `anvil` fork when `FORK=1`.
- **Transactions** only ever go to the fork: the site's three RPC hosts and an injected EIP-1193/EIP-6963 test wallet are routed to `anvil`, which impersonates a fresh address (`ACCOUNT`), so no key is needed and nothing touches live Sepolia.
- `fork-answer.sh <project> yes|no|fail` answers a project's open question **on the fork only**: it swaps the registry's oracle signer (storage slot 2) for a test key, impersonates the Intake and sends a signed `onOracleResult`, or an `onOracleFailure`. That is how `Listed`, `Defended`, `Delisted` and `AskCleared` are shown without the real panel.

## Run

Needs Node 22, Playwright (here `/opt/node-tools/node_modules/playwright` with Chromium in `/opt/pw-browsers`) and Foundry 1.8.3.

```sh
cd tools/site-check && npm install
anvil --fork-url https://rpc.sepolia.ethpandaops.io --chain-id 11155111 --port 8545 --silent &
node layout.mjs                 # every route, 360/768/1280, both themes, live reads
node behavior.mjs               # menu, keyboard, back/forward, deep links, docs nav, theme, /llms.txt
# flows.mjs expects two fork fixtures: TestSIMD's address listed, TestIMD's address with an open question
node flows.mjs                  # wallet flows and form errors on the fork (WIDTH=360 for mobile)
FORK=1 PROJECTS=0x…,0x… node layout.mjs   # the same matrix with a populated registry
node refresh-bug.mjs            # does a data refresh remove the Apply question or a field error?
```

`SITE` overrides the site URL. Results print as PASS/FAIL lines; `layout.mjs` also writes `layout-live.json` or `layout-fork.json`.

## Listing trial through the root site

`trial.mjs` runs one step of the registry trial through the GitHub Pages site (https://imdacc.fun/), with a wallet that signs as the test wallet `0x4b91…6821` (key from `PONDPAD_TESTNET_KEY`, never printed). The page finds it as `window.ethereum`, like MetaMask or Rabby.

```sh
TARGET=http://127.0.0.1:8545 node trial.mjs plea        # rehearsal on the fork: the page's RPCs go there too
LIVE_OK=1 TARGET=https://ethereum-sepolia-rpc.publicnode.com node trial.mjs plea   # live Sepolia: owner's approval first
```

Steps: `plea` (approve the fee, `applyListing` for PLEA's hook at 50 bps), `selfcredit` (the same for `SelfCredit`), `apply` (`PROJECT`, `NAME`, `URL`, optional `RATE` and `BENEFICIARY`), `challenge` (`PROJECT`, default PLEA's hook: mint 10 oracle test IMD and approve fee + bond only when the wallet is short, then `challengeForBeneficiary` from the project page; a failed gas estimate is retried, since a public RPC node behind the head may not see the approval yet). Each step caps how many transactions it may send. On the fork, `fork-answer.sh` plays the panel's answer between steps (and `cast rpc evm_increaseTime 3601` passes the cooldown).

## Robinhood Chain on a fork

`robinhood-fork.mjs` runs the Robinhood Chain pages through the site on a local fork, with the test wallet impersonated (no key): Your Stack's "Flush my cashback now" (the wallet starts without Robinhood Chain, so the site must add it with `wallet_addEthereumChain`), then an application from the Apply page. Fork from the official RPC, which serves old logs (publicnode refuses them), and restart the fork between runs (a run flushes the wallet's waiting cashback).

```sh
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8546 --silent &
ANVIL=http://127.0.0.1:8546 NETWORK=robinhood ACCOUNT=0x4b91078b2374c956a65f7af0999cae0a935e6821 SITE=http://127.0.0.1:8787/ node robinhood-fork.mjs
```

`lib.mjs` takes `NETWORK` (the site's network for any check, Sepolia by default), routes the Robinhood Chain RPC hosts to the fork too, and answers `eth_chainId` with the fork's chain id.
