# imd/acc data API (snapshot files, version 1)

Read-only JSON files with every chain's cashback and points totals, rebuilt from the chain about every 15 minutes and published with the website. No key, no server: fetch them from any site or script (`Access-Control-Allow-Origin: *`).

| File | What it holds |
|---|---|
| [`https://imdacc.fun/data/v1/index.json`](https://imdacc.fun/data/v1/index.json) | The chains that have a file, with each file's last block. Start here. |
| [`https://imdacc.fun/data/v1/sepolia.json`](https://imdacc.fun/data/v1/sepolia.json) | Sepolia: the test run 2 Stacker and the test run 6 registry (since 2026-10-12; before, test runs 4 and 5). |
| [`https://imdacc.fun/data/v1/ethereum.json`](https://imdacc.fun/data/v1/ethereum.json) | Ethereum mainnet: the Stacker of launch #1409 and the ProjectRegistry of launch #1495 (since 2026-10-13; before, `contracts.registry` was `null` and no credit earned points). |

The builder is [`tools/snapshot/build.mjs`](../tools/snapshot/build.mjs) (chains in [`tools/snapshot/chains.json`](../tools/snapshot/chains.json)); the website's workflow runs it on a schedule, on every push to `main`, and on demand.

## Rules the numbers follow

- **Everything comes from events,** recomputed from scratch on every run: the Stacker's `Stacked(project, trader, imd, shares)` and the chain's ProjectRegistry (`Applied`, `Listed`, `Rejected`, `Challenged`, `Defended`, `Delisted`, `AskCleared`, `BeneficiarySet`).
- **Confirmed blocks only:** a file counts every event up to `blocks.to`, which stays 12 blocks behind the chain's head, so a reorg doesn't change it.
- **Points:** 1 point per IMD stacked by a project **inside one of its listing periods**: a credit in block `b` counts when `from <= b` and (`to` is null or `b < to`). Credits before listing, after delisting, from unlisted contracts or from wallets count as IMD stacked but earn no points. A project's points are the IMD its traders stacked while it was listed.
- **Checked:** the IMD of all events must equal the Stacker's `totalStacked()` at `blocks.to`, and each project's IMD and shares its `projectStacked` and `projectShares`. A file that fails the check isn't published; the previous one stays.
- **Points are a record, not a promise.** Nothing is owed for them. Rate checks per credit (a credit outside 25-100 bps of its trade) aren't applied yet; when they are, the file's `version` goes up.

## Format

All amounts are **strings holding whole numbers in the token's smallest unit**, so they never lose precision in JavaScript: IMD and points use `tokens.imd.decimals` (18: `"1000000000000000000"` is 1 IMD or 1 point), shares use `tokens.sImd.decimals` (24 on Ethereum and Sepolia). Addresses are lowercase. Times are ISO 8601 in UTC.

### `index.json`

```json
{
 "schema": "imdacc.snapshot.index",
 "version": 1,
 "generatedAt": "2026-10-12T12:45:02.000Z",
 "chains": [
  { "id": 11155111, "name": "sepolia", "file": "sepolia.json", "toBlock": 11898947, "toTime": "2026-10-12T12:39:24.000Z", "generatedAt": "2026-10-12T12:45:01.000Z" }
 ]
}
```

### `<chain>.json`

```json
{
 "schema": "imdacc.snapshot",
 "version": 1,
 "chain": { "id": 11155111, "name": "sepolia" },
 "generatedAt": "2026-10-12T12:45:01.000Z",
 "blocks": { "from": 11891109, "to": 11898947, "toTime": "2026-10-12T12:39:24.000Z" },
 "contracts": { "stacker": "0x0457…314d", "registry": "0x30a3…3384", "registryFromBlock": 11900978 },
 "tokens": { "imd": { "address": "0x2b69…1e82", "decimals": 18 }, "sImd": { "address": "0xf9e2…1cc1", "decimals": 24 } },
 "totals": { "imd": "1280881069203285333", "shares": "…", "points": "0", "credits": 6, "traders": 2, "projects": 2, "listedProjects": 1 },
 "projects": [
  {
   "address": "0x2d5a…a8cc", "name": "PLEA", "sourceUrl": "https://…", "status": "listed",
   "rateBps": 50, "beneficiary": "0x4b91…6821", "periods": [ { "from": 11898188, "to": null } ],
   "imd": "280881069203285333", "shares": "…", "points": "0", "credits": 5, "traders": 2, "pointTraders": 0
  }
 ],
 "traders": [
  {
   "address": "0xb0d5…0712", "imd": "172417478720027393", "shares": "…", "points": "0", "credits": 3,
   "projects": { "0x2d5a…a8cc": { "imd": "172417478720027393", "shares": "…", "points": "0", "credits": 3 } }
  }
 ]
}
```

(Addresses shortened here; the files carry them in full.)

| Field | Meaning |
|---|---|
| `blocks.from`, `blocks.to`, `blocks.toTime` | The Stacker's deploy block, and the last block counted with its time. |
| `contracts.registry` | The registry whose listing periods give points; `null` on a chain without one (then no credit earns points). |
| `totals` | Sums over the file: `imd`, `shares` and `points`; `credits` (number of `Stacked` events), `traders` and `projects` (distinct addresses), `listedProjects` (status `listed`). |
| `projects[]` | Every contract or wallet that credited through the Stacker, and every project in the registry, sorted by points, then IMD. |
| `projects[].status` | `listed`; `applied` (application open); `challenged` (challenge open, still listed); `rejected`; `delisted`; `cleared` (the last application ended without an answer); `direct` (never in the registry: its credits are staking for someone, no points). |
| `projects[].rateBps`, `beneficiary` | From the registry: the rate (25-100 bps) and the wallet holding the project's points; `null` for `direct`. |
| `projects[].periods[]` | Listing periods, `{from, to}`: `to` is the block it was delisted, `null` while listed. |
| `projects[].imd`, `shares`, `credits`, `traders` | Everything credited through the Stacker by this project, listed or not. |
| `projects[].points`, `pointTraders` | Only credits inside its listing periods, and how many traders earned them. |
| `traders[]` | Every address that received a credit, sorted by points, then IMD, with the same figures and a split per project (`projects`, keyed by project address). |

`name` and `sourceUrl` are what the applicant typed: show them as untrusted text.

## Stability

- **Version 1 doesn't change** in a way that breaks a reader: fields keep their names, types and meaning, and the files keep their URLs under `/data/v1/`. New fields may be added; ignore the ones you don't know.
- A change that would break a reader (a renamed field, a new rule for points, files split for size) comes as `/data/v2/`, published next to v1 for a while and announced in this document.
- **Freshness:** files are typically 15-30 minutes behind the chain (a 15-minute schedule that GitHub may delay, 12 confirmations, and up to 10 minutes of caching). Read `blocks.to` and `blocks.toTime` instead of assuming. For live figures, read the events after `blocks.to` from the chain yourself.
- GitHub turns off a repository's scheduled workflows after 60 days without activity; a push or a manual run turns them back on.

## Example

```js
const index = await (await fetch("https://imdacc.fun/data/v1/index.json")).json();
const snap = await (await fetch("https://imdacc.fun/data/v1/" + index.chains[0].file)).json();
const me = snap.traders.find((t) => t.address === wallet.toLowerCase());
const points = me ? Number(BigInt(me.points) / 10n ** 14n) / 1e4 : 0; // 4 decimals
```
