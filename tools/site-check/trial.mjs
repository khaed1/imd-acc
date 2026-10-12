// One step of the listing trial through the website, signed by the test wallet.
// usage: TARGET=<rpc> node trial.mjs plea|selfcredit|apply|challenge
// apply: PROJECT, NAME, URL (RATE 50, BENEFICIARY the test wallet); challenge: PROJECT (default PLEA's hook).
// TARGET=http://127.0.0.1:8545 rehearses on the local fork (the page's RPCs are routed there too);
// live Sepolia needs LIVE_OK=1. The key comes from PONDPAD_TESTNET_KEY and is never printed.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { createRequire } from "node:module";
const run = promisify(execFile);
const require = createRequire("/opt/node-tools/node_modules/");
const { chromium } = require("playwright");

const STEP = process.argv[2];
const TARGET = process.env.TARGET || "https://ethereum-sepolia-rpc.publicnode.com";
const LIVE = !/127\.0\.0\.1|localhost/.test(TARGET);
if (LIVE && process.env.LIVE_OK !== "1") throw new Error("live Sepolia needs LIVE_OK=1");
const SITE = process.env.SITE || "https://imdacc.fun/";
const ACCOUNT = "0x4b91078b2374c956a65f7af0999cae0a935e6821";
const HOOK = "0x2d5a03d5bab98a4a435edad11813373963bca8cc";
const SC = "0x3d1778be5f9e55f0df35acaf64a13efe2fe81488";
const PLEA_URL = "https://eth-sepolia.blockscout.com/address/0x2d5A03d5bAb98a4a435edad11813373963bcA8cC?tab=contract";
const SC_URL = "https://repo.sourcify.dev/11155111/0x3D1778bE5f9E55f0dF35ACAF64A13Efe2FE81488";
const REASON = "Trial challenge: please check that the hook still credits 50 bps of each trade from its own fees and that the fee guard still holds.";
const MAX_TX = { plea: 2, selfcredit: 2, apply: 2, challenge: 3 }[STEP];
if (!MAX_TX) throw new Error("step: plea | selfcredit | apply | challenge");
const TARGET_PROJECT = (process.env.PROJECT || HOOK).toLowerCase();
const CAST = `${process.env.HOME}/.foundry/bin/cast`;
const RPC_HOSTS = /rpc\.sepolia\.ethpandaops\.io|ethereum-sepolia-rpc\.publicnode\.com|sepolia\.drpc\.org/;

async function rpc(method, params) {
  const r = await fetch(TARGET, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  return r.json();
}

const sent = [];
async function sendTransaction(tx) {
  if (sent.length >= MAX_TX) return { error: { code: 4001, message: `step ${STEP} allows ${MAX_TX} transactions` } };
  const to = tx.to.toLowerCase();
  const data = tx.data || tx.input || "0x";
  const args = ["send", to, data, "--gas-limit", String(BigInt(tx.gas)), "--rpc-url", TARGET, "--async", "--private-key", process.env.PONDPAD_TESTNET_KEY];
  try {
    const { stdout } = await run(CAST, args);
    const hash = stdout.trim().split(/\s+/).pop();
    sent.push({ hash, to, sel: data.slice(0, 10), gas: Number(BigInt(tx.gas)) });
    console.log(`  sent ${data.slice(0, 10)} to ${to}: ${hash}`);
    return { result: hash };
  } catch (e) {
    return { error: { code: -32603, message: String(e.stderr || e.message).replaceAll(process.env.PONDPAD_TESTNET_KEY, "<key>").slice(0, 300) } };
  }
}

const INIT = `(() => {
  const listeners = {};
  const emit = (ev, v) => (listeners[ev] || []).forEach((f) => { try { f(v); } catch (e) {} });
  const provider = {
    request: async ({ method, params }) => {
      const r = JSON.parse(await window.__walletRpc(JSON.stringify({ method, params: params || [] })));
      if (r.error) { const e = new Error(r.error.message); e.code = r.error.code; throw e; }
      if (method === "eth_requestAccounts") setTimeout(() => emit("accountsChanged", r.result), 0);
      return r.result;
    },
    on(ev, f) { (listeners[ev] = listeners[ev] || []).push(f); return provider; },
    removeListener(ev, f) { listeners[ev] = (listeners[ev] || []).filter((g) => g !== f); return provider; },
  };
  window.ethereum = provider;
})();`;

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
const page = await context.newPage();
const errors = [];
page.on("pageerror", (e) => errors.push(e.message));
page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
if (!LIVE) {
  await context.route(RPC_HOSTS, async (route) => {
    const req = route.request();
    const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "*" };
    if (req.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors });
    const r = await fetch(TARGET, { method: "POST", headers: { "content-type": "application/json" }, body: req.postData() });
    return route.fulfill({ status: r.status, headers: { ...cors, "content-type": "application/json" }, body: await r.text() });
  });
}
await page.exposeFunction("__walletRpc", async (s) => {
  const { method, params } = JSON.parse(s);
  if (method === "eth_requestAccounts" || method === "eth_accounts") return JSON.stringify({ result: [ACCOUNT] });
  if (method === "eth_chainId") return JSON.stringify({ result: "0xaa36a7" });
  if (method === "wallet_switchEthereumChain" || method === "wallet_addEthereumChain") return JSON.stringify({ result: null });
  if (method === "eth_sendTransaction") return JSON.stringify(await sendTransaction(params[0]));
  if (method === "eth_estimateGas") {
    let r;
    for (let i = 0; i < 4; i++) { // a node behind the head may not see the approval yet
      r = await rpc(method, params);
      if (!r.error) break;
      await new Promise((f) => setTimeout(f, 3000));
    }
    return JSON.stringify(r);
  }
  return JSON.stringify(await rpc(method, params));
});
await page.addInitScript(INIT);

async function waitSent(n, label, sel) {
  const ready = () => (sel ? sent.some((t) => t.sel === sel) : sent.length >= n);
  for (let i = 0; i < 240 && !ready(); i++) await page.waitForTimeout(250);
  if (!ready()) {
    const toast = (await page.locator("#toast-text").textContent().catch(() => "")) || "";
    const form = (await page.locator("#step-apply-disabled").textContent().catch(() => "")) || "";
    throw new Error(`${label}: not sent; page says: ${toast} ${form}`.trim());
  }
  const tx = sel ? sent.find((t) => t.sel === sel) : sent[n - 1];
  for (let i = 0; i < 120; i++) {
    const r = (await rpc("eth_getTransactionReceipt", [tx.hash])).result;
    if (r) { console.log(`  ${label}: ${r.status === "0x1" ? "confirmed" : "REVERTED"} in block ${Number(r.blockNumber)}, gas used ${Number(r.gasUsed).toLocaleString("en-US")}`); await page.waitForTimeout(4000); return r; }
    await page.waitForTimeout(2000);
  }
  throw new Error(`${label}: no receipt after 4 minutes`);
}

async function apply(v) {
  await page.goto(SITE + "#/apply", { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(5000);
  await page.click("#btn-wallet");
  await page.waitForTimeout(4000);
  for (const [id, val] of Object.entries(v)) { const el = page.locator(`#apply-${id}`); await el.fill(val); await el.blur(); }
  await page.waitForTimeout(2500);
  console.log("  question:", (await page.locator("#apply-question code").textContent()).trim());
  await page.click("#btn-approve-fee"); await waitSent(1, "approve fee");
  await page.click("#btn-apply-listing"); await waitSent(2, "applyListing");
  console.log("  page:", (await page.locator("#step-apply-disabled").textContent()).trim());
}

console.log(`${STEP} on ${LIVE ? "LIVE Sepolia" : "the local fork"} through ${SITE}`);
if (STEP === "plea") await apply({ project: HOOK, name: "PLEA", url: PLEA_URL, rate: "50", beneficiary: ACCOUNT });
if (STEP === "selfcredit") await apply({ project: SC, name: "SelfCredit trial", url: SC_URL, rate: "50", beneficiary: ACCOUNT });
if (STEP === "apply") await apply({ project: TARGET_PROJECT, name: process.env.NAME, url: process.env.URL, rate: process.env.RATE || "50", beneficiary: process.env.BENEFICIARY || ACCOUNT });
if (STEP === "challenge") {
  await page.goto(SITE + "#/apply", { waitUntil: "domcontentloaded" });
  await page.waitForTimeout(5000);
  await page.click("#btn-wallet");
  await page.waitForTimeout(4000);
  // Fee token balance and allowance of the test wallet: mint and approve only when short (a rerun).
  const FEE_TOKEN = "0x44a1cd38474fb1748400e7deb5f8d786cce3f89a", REGISTRY = "0x5f63cdead0f5f693b8964d82b56155f55645ccea";
  const pad = (a) => a.slice(2).padStart(64, "0");
  const balance = BigInt((await rpc("eth_call", [{ to: FEE_TOKEN, data: "0x70a08231" + pad(ACCOUNT) }, "latest"])).result);
  const allowance = BigInt((await rpc("eth_call", [{ to: FEE_TOKEN, data: "0xdd62ed3e" + pad(ACCOUNT) + pad(REGISTRY) }, "latest"])).result);
  const needed = 5_500_000_000_000_000_000n;
  if (balance < needed) { await page.click("#btn-get-feetoken"); await waitSent(1, "mint 10 oracle test IMD", "0x40c10f19"); } else console.log("  fee token balance is enough, no mint");
  await page.goto(SITE + `#/projects/${TARGET_PROJECT}`); await page.waitForTimeout(5000);
  await page.fill("#ch-reason", REASON);
  await page.click("#btn-submit-challenge");
  if (allowance < needed) await waitSent(0, "approve fee + bond", "0x095ea7b3"); else console.log("  allowance is enough, no approve");
  await waitSent(0, "challengeForBeneficiary", "0x55b2aebb");
}
for (const t of sent) console.log(`TX ${t.sel} ${t.hash}`);
console.log("page errors:", errors.length ? errors : "none");
await browser.close();
