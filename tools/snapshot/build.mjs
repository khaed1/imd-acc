// Builds the imd/acc data snapshot (format: docs/data-api.md), one file per chain plus an index.
// Every run recomputes everything from the chain: the Stacker's Stacked events (on a chain with a
// RemoteStacker, `"kind": "remote"`, its Queued events) and the registry's listing events up to a
// confirmed block, then checks the totals against the Stacker's (or RemoteStacker's) own.
//
// usage: node tools/snapshot/build.mjs [--out data/v1] [--chains tools/snapshot/chains.json]
//                                      [--fallback https://imdacc.fun/data/v1/] [--rpc <url>]
// --fallback: if a chain fails, keep the file already published there (it carries its own block).
// --rpc: use this RPC for every chain (a local fork in tests). --confirmations: blocks to stay behind the head.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const SCHEMA = "imdacc.snapshot";
const VERSION = 1;

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith("--") ? [...acc, [a.slice(2), all[i + 1]]] : acc), []),
);
const OUT = args.out || "data/v1";
const CHAINS = JSON.parse(readFileSync(args.chains || new URL("./chains.json", import.meta.url), "utf8"));

// keccak256 of each event signature and function selectors (checked by tools/snapshot/test.sh with `cast`).
const TOPIC = {
  Stacked: "0x7fbd7b0bc9aac1aa6f42ea64666fad17288ea759411a11f4231a958bc31838c6",
  Queued: "0x230276f3d1b1026907db52455ecd27f5c8ca695d499d8e28d51d8a0c8851e2db",
  Delivering: "0x7f64657283b1a94fa9965ae9e7c5b20fecc8244b996da445899d1f9175376f88",
  Applied: "0xb7e8095de4cf7043336c1e0ece05439714eb277c7cb5deed1b4f2479e4a6d173",
  Listed: "0x518fc40ea95a380fb5f45f1ad72398fdefb809c6dfebc59d2236045bd1d10267",
  Rejected: "0xf8a1bb90febbb3cd262033228521e367e8bba1bc6c61eee6bcfa744fafb31f4a",
  Challenged: "0x43993779a041d6ad7d4dceb299983e61e87565d974db929ff04933734959cd0e",
  Defended: "0x42d2c8660fea33f766be7cfab644ef179a97c26621566727cbcb6ae7986963a9",
  Delisted: "0x0f4e3ebc43292a7ecf57e30d244481c276bb21cb84f14905ce5786ddcfe2908a",
  AskCleared: "0x479ec138af9f4c82591accadecba9be18b659e2389b0629555e011f33a6b97d4",
  BeneficiarySet: "0x2906d223dc4163733bb374af8641c7e9ae256e2bae53c90e0c9a2be2e611ae44",
};
const NAME_OF = Object.fromEntries(Object.entries(TOPIC).map(([k, v]) => [v, k]));
const SEL = {
  IMD: "0xd0abb693",
  SIMD: "0x8fb56bef",
  totalStacked: "0x29eae70d",
  projectStacked: "0x55109313",
  projectShares: "0x41581358",
  decimals: "0x313ce567",
  // RemoteStacker (chains with "kind": "remote")
  VAULT: "0x411557d1",
  RECEIVER: "0xad7430cc",
  totalQueued: "0x53ac4b66",
  projectQueued: "0x11c10f98",
  waiting: "0xe437786d",
};

// ---------------------------------------------------------------- RPC

async function rpcOnce(url, method, params) {
  const r = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
    signal: AbortSignal.timeout(30_000),
  });
  if (!r.ok) throw new Error(`${url} ${method}: HTTP ${r.status}`);
  const j = await r.json();
  if (j.error) throw new Error(`${url} ${method}: ${j.error.message}`);
  return j.result;
}

function client(rpcs) {
  return async (method, params) => {
    let last;
    for (const url of rpcs) {
      for (let attempt = 0; attempt < 2; attempt++) {
        try {
          return await rpcOnce(url, method, params);
        } catch (e) {
          last = e;
          await new Promise((r) => setTimeout(r, 500 * (attempt + 1)));
        }
      }
    }
    throw last;
  };
}

const hex = (n) => "0x" + n.toString(16);
const word = (data, i) => data.slice(2 + i * 64, 2 + (i + 1) * 64);
const uint = (data, i) => BigInt("0x" + word(data, i));
const addrWord = (w) => "0x" + w.slice(-40).toLowerCase();
const topicAddr = (t) => "0x" + t.slice(-40).toLowerCase();
function str(data, i) {
  const off = Number(uint(data, i)) * 2 + 2;
  const len = Number(BigInt("0x" + data.slice(off, off + 64)));
  return Buffer.from(data.slice(off + 64, off + 64 + len * 2), "hex").toString("utf8");
}

// eth_getLogs over [from, to], split into ranges; a range an RPC refuses is halved and retried.
async function getLogs(rpc, address, from, to) {
  const logs = [];
  let start = from;
  let size = 50_000;
  while (start <= to) {
    const end = Math.min(to, start + size - 1);
    try {
      logs.push(...(await rpc("eth_getLogs", [{ address, fromBlock: hex(start), toBlock: hex(end) }])));
      start = end + 1;
    } catch (e) {
      if (size <= 500) throw e;
      size = Math.floor(size / 2);
    }
  }
  return logs;
}

const call = (rpc, to, data, block) => rpc("eth_call", [{ to, data }, hex(block)]);
const padAddr = (a) => a.toLowerCase().replace(/^0x/, "").padStart(64, "0");

// ---------------------------------------------------------------- build one chain

async function buildChain(chain) {
  const rpc = client(args.rpc ? [args.rpc] : chain.rpcs);
  const head = Number(await rpc("eth_blockNumber", []));
  const toBlock = head - Number(args.confirmations ?? chain.confirmations ?? 12);
  const block = await rpc("eth_getBlockByNumber", [hex(toBlock), false]);
  const stacker = chain.stacker.toLowerCase();
  const registry = chain.registry ? chain.registry.toLowerCase() : null;
  // A RemoteStacker queues cashback here and delivers it to the sIMD vault on Ethereum, so the
  // vault (and its decimals) live on another chain: chains.json names it and the contract must agree.
  const remote = chain.kind === "remote";

  const imdAddr = addrWord((await call(rpc, stacker, SEL.IMD, toBlock)).slice(2));
  const simdAddr = addrWord((await call(rpc, stacker, remote ? SEL.VAULT : SEL.SIMD, toBlock)).slice(2));
  const imdDecimals = Number(BigInt(await call(rpc, imdAddr, SEL.decimals, toBlock)));
  let simdDecimals;
  let receiver = null;
  if (remote) {
    if (simdAddr !== chain.vault.address.toLowerCase()) throw new Error(`${chain.name}: VAULT() is ${simdAddr}, chains.json says ${chain.vault.address}`);
    simdDecimals = chain.vault.decimals;
    receiver = addrWord((await call(rpc, stacker, SEL.RECEIVER, toBlock)).slice(2));
  } else {
    simdDecimals = Number(BigInt(await call(rpc, simdAddr, SEL.decimals, toBlock)));
  }

  // Registry: every project's record and listing periods, from its events.
  const projects = new Map();
  const project = (a) => {
    if (!projects.has(a)) {
      projects.set(a, {
        address: a, name: null, sourceUrl: null, status: "direct", rateBps: null, beneficiary: null,
        periods: [], imd: 0n, shares: 0n, credits: 0, traders: new Set(), points: 0n, pointTraders: new Set(),
        inRegistry: false, ask: null, lastOutcome: null,
      });
    }
    return projects.get(a);
  };
  const regLogs = registry ? await getLogs(rpc, registry, chain.registryBlock, toBlock) : [];
  regLogs.sort((a, b) => Number(a.blockNumber) - Number(b.blockNumber) || Number(a.logIndex) - Number(b.logIndex));
  for (const log of regLogs) {
    const kind = NAME_OF[log.topics[0]];
    if (!kind || !log.topics[1]) continue;
    const p = project(topicAddr(log.topics[1]));
    const d = log.data;
    p.inRegistry = true;
    if (kind === "Applied") {
      p.ask = "apply";
      if (!p.periods.some((x) => x.to === null)) {
        p.rateBps = Number(uint(d, 0));
        p.beneficiary = addrWord(word(d, 1));
      }
      p.name = str(d, 2);
      p.sourceUrl = str(d, 3);
    } else if (kind === "Listed") {
      p.ask = null;
      p.rateBps = Number(uint(d, 0));
      p.beneficiary = addrWord(word(d, 1));
      p.periods.push({ from: Number(uint(d, 2)), to: null });
      p.lastOutcome = "listed";
    } else if (kind === "Rejected") {
      p.ask = null;
      p.lastOutcome = "rejected";
    } else if (kind === "Challenged") {
      p.ask = "challenge";
    } else if (kind === "Defended") {
      p.ask = null;
    } else if (kind === "Delisted") {
      p.ask = null;
      const open = p.periods.find((x) => x.to === null);
      if (open) open.to = Number(uint(d, 0));
      p.lastOutcome = "delisted";
    } else if (kind === "AskCleared") {
      p.ask = null;
      if (!p.periods.some((x) => x.to === null)) p.lastOutcome = "cleared";
    } else if (kind === "BeneficiarySet") {
      p.beneficiary = addrWord(word(d, 0));
    }
  }
  const listedAt = (p, b) => p.periods.some((r) => b >= r.from && (r.to === null || b < r.to));

  // Stacker: every credit; points only inside a listing period of its project. On a remote chain a
  // credit is a Queued(project, trader, recipient, imd) event: no shares yet (the vault mints them on
  // Ethereum at delivery), and a contract wallet paid plain IMD here (Paid) is not a credit.
  const traders = new Map();
  const stackLogs = await getLogs(rpc, stacker, chain.stackerBlock, toBlock);
  let totalImd = 0n;
  let totalShares = 0n;
  let totalPoints = 0n;
  let credits = 0;
  const queuedTo = new Map(); // remote: Ethereum recipient -> IMD queued, delivered and tipped
  const recipientOf = (r) => {
    if (!queuedTo.has(r)) queuedTo.set(r, { queued: 0n, delivered: 0n, tips: 0n });
    return queuedTo.get(r);
  };
  let delivered = 0n;
  let tips = 0n;
  for (const log of stackLogs) {
    if (remote && log.topics[0] === TOPIC.Delivering) {
      const r = recipientOf(topicAddr(log.topics[2]));
      r.delivered += uint(log.data, 0);
      r.tips += uint(log.data, 1);
      delivered += uint(log.data, 0);
      tips += uint(log.data, 1);
      continue;
    }
    if (log.topics[0] !== (remote ? TOPIC.Queued : TOPIC.Stacked)) continue;
    const p = project(topicAddr(log.topics[1]));
    const t = topicAddr(log.topics[2]);
    const imd = uint(log.data, remote ? 1 : 0);
    const shares = remote ? 0n : uint(log.data, 1);
    if (remote) recipientOf(addrWord(word(log.data, 0))).queued += imd;
    const b = Number(log.blockNumber);
    const pts = listedAt(p, b) ? imd : 0n;
    if (!traders.has(t)) traders.set(t, { address: t, imd: 0n, shares: 0n, credits: 0, points: 0n, byProject: new Map() });
    const tr = traders.get(t);
    const tp = tr.byProject.get(p.address) || { imd: 0n, shares: 0n, credits: 0, points: 0n };
    for (const o of [p, tr, tp]) { o.imd += imd; o.shares += shares; o.credits += 1; o.points += pts; }
    tr.byProject.set(p.address, tp);
    p.traders.add(t);
    if (pts > 0n) p.pointTraders.add(t);
    totalImd += imd;
    totalShares += shares;
    totalPoints += pts;
    credits += 1;
  }

  // Integrity: the events must add up to the Stacker's own totals at the same block (on a remote
  // chain: totalQueued, projectQueued, and each recipient's waiting balance).
  const onchainTotal = BigInt(await call(rpc, stacker, remote ? SEL.totalQueued : SEL.totalStacked, toBlock));
  if (onchainTotal !== totalImd) throw new Error(`${chain.name}: events sum ${totalImd} but the on-chain total is ${onchainTotal} at ${toBlock}`);
  for (const p of projects.values()) {
    if (p.credits === 0) continue;
    if (remote) {
      const q = BigInt(await call(rpc, stacker, SEL.projectQueued + padAddr(p.address), toBlock));
      if (q !== p.imd) throw new Error(`${chain.name}: ${p.address} events ${p.imd} but projectQueued ${q}`);
      continue;
    }
    const s = BigInt(await call(rpc, stacker, SEL.projectStacked + padAddr(p.address), toBlock));
    const sh = BigInt(await call(rpc, stacker, SEL.projectShares + padAddr(p.address), toBlock));
    if (s !== p.imd || sh !== p.shares) throw new Error(`${chain.name}: ${p.address} events ${p.imd}/${p.shares} but on chain ${s}/${sh}`);
  }
  let waitingTotal = 0n;
  for (const [r, v] of queuedTo) {
    const w = v.queued - v.delivered - v.tips;
    const onchain = BigInt(await call(rpc, stacker, SEL.waiting + padAddr(r), toBlock));
    if (w !== onchain) throw new Error(`${chain.name}: ${r} events leave ${w} waiting but waiting() is ${onchain}`);
    waitingTotal += w;
  }

  const status = (p) => {
    if (!p.inRegistry) return "direct";
    if (p.ask === "apply") return "applied";
    if (p.ask === "challenge") return "challenged";
    if (p.periods.some((x) => x.to === null)) return "listed";
    return p.lastOutcome === "listed" ? "delisted" : p.lastOutcome || "applied";
  };
  const byAmount = (k) => (x, y) => (y[k] > x[k] ? 1 : y[k] < x[k] ? -1 : 0);
  const desc = (x, y) => byAmount("points")(x, y) || byAmount("imd")(x, y) || (x.address < y.address ? -1 : 1);
  const s = (n) => n.toString();

  return {
    schema: SCHEMA,
    version: VERSION,
    chain: { id: chain.id, name: chain.name },
    generatedAt: new Date().toISOString(),
    blocks: { from: chain.stackerBlock, to: toBlock, toTime: new Date(Number(block.timestamp) * 1000).toISOString() },
    contracts: {
      stacker, registry, registryFromBlock: registry ? chain.registryBlock : null,
      kind: remote ? "remote" : "stacker",
      ...(remote ? { receiver, receiverChainId: chain.vault.chainId } : {}),
    },
    tokens: {
      imd: { address: imdAddr, decimals: imdDecimals },
      sImd: { address: simdAddr, decimals: simdDecimals, ...(remote ? { chainId: chain.vault.chainId } : {}) },
    },
    totals: {
      imd: s(totalImd), shares: s(totalShares), points: s(totalPoints), credits, traders: traders.size,
      projects: [...projects.values()].filter((p) => p.credits > 0 || p.inRegistry).length,
      listedProjects: [...projects.values()].filter((p) => status(p) === "listed").length,
      ...(remote ? { waiting: s(waitingTotal), delivered: s(delivered), tips: s(tips) } : {}),
    },
    projects: [...projects.values()].filter((p) => p.credits > 0 || p.inRegistry).sort(desc).map((p) => ({
      address: p.address,
      name: p.name,
      sourceUrl: p.sourceUrl,
      status: status(p),
      rateBps: p.rateBps,
      beneficiary: p.beneficiary,
      periods: p.periods.map((r) => ({ from: r.from, to: r.to })),
      imd: s(p.imd), shares: s(p.shares), points: s(p.points),
      credits: p.credits, traders: p.traders.size, pointTraders: p.pointTraders.size,
    })),
    traders: [...traders.values()].sort(desc).map((t) => ({
      address: t.address,
      imd: s(t.imd), shares: s(t.shares), points: s(t.points), credits: t.credits,
      projects: Object.fromEntries([...t.byProject.entries()].sort().map(([a, v]) => [a, { imd: s(v.imd), shares: s(v.shares), points: s(v.points), credits: v.credits }])),
    })),
  };
}

// ---------------------------------------------------------------- main

mkdirSync(OUT, { recursive: true });
const index = { schema: SCHEMA + ".index", version: VERSION, generatedAt: new Date().toISOString(), chains: [] };
let failed = 0;
for (const chain of CHAINS) {
  const file = `${chain.name}.json`;
  let snap;
  try {
    snap = await buildChain(chain);
    console.log(`${chain.name}: blocks ${snap.blocks.from}-${snap.blocks.to}, ${snap.totals.credits} credits, ${snap.totals.traders} traders, ${snap.totals.listedProjects} listed`);
  } catch (e) {
    failed++;
    console.log(`::warning::snapshot ${chain.name} failed: ${e.message}`);
    if (!args.fallback) continue;
    try {
      const r = await fetch(args.fallback + file, { signal: AbortSignal.timeout(30_000) });
      if (!r.ok) throw new Error(`HTTP ${r.status}`);
      snap = await r.json();
      if (snap.schema !== SCHEMA || snap.version !== VERSION) throw new Error("not a v1 snapshot");
      console.log(`${chain.name}: kept the published file (block ${snap.blocks.to})`);
    } catch (e2) {
      console.log(`::warning::no published ${file} to keep: ${e2.message}`);
      continue;
    }
  }
  writeFileSync(join(OUT, file), JSON.stringify(snap, null, 1) + "\n");
  index.chains.push({ id: snap.chain.id, name: snap.chain.name, file, toBlock: snap.blocks.to, toTime: snap.blocks.toTime, generatedAt: snap.generatedAt });
}
writeFileSync(join(OUT, "index.json"), JSON.stringify(index, null, 1) + "\n");
if (failed && process.env.SNAPSHOT_STRICT) process.exit(1);
