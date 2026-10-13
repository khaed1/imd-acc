// Browser harness for the imd/acc Sepolia site: live reads, or every RPC host and an injected
// EIP-1193/EIP-6963 test wallet routed to a local anvil Sepolia fork.
import { createRequire } from "node:module";
import { readFileSync } from "node:fs";
const require = createRequire("/opt/node-tools/node_modules/");
const { chromium } = require("playwright");

export const ANVIL = process.env.ANVIL || "http://127.0.0.1:8545";
export const ACCOUNT = (process.env.ACCOUNT || "0xa987EF2AA4d2c0558CC6405F1A8253507274Dc5d").toLowerCase();
export const RPC_HOSTS = /rpc\.sepolia\.ethpandaops\.io|sepolia\.rpc\.sentio\.xyz|ethereum-sepolia-rpc\.publicnode\.com|sepolia\.drpc\.org/;
const AXE = readFileSync(new URL("./node_modules/axe-core/axe.min.js", import.meta.url), "utf8");

export async function anvil(method, params = []) {
  const r = await fetch(ANVIL, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message}`);
  return j.result;
}

export async function prepareAccount() {
  await anvil("anvil_impersonateAccount", [ACCOUNT]);
  await anvil("anvil_setBalance", [ACCOUNT, "0x56BC75E2D63100000"]); // 100 ETH
}

export async function launch() {
  return chromium.launch({ headless: true });
}

const WALLET_INIT = `(() => {
  const listeners = {};
  const emit = (ev, v) => (listeners[ev] || []).forEach((f) => { try { f(v); } catch (e) {} });
  const provider = {
    request: async ({ method, params }) => {
      const r = JSON.parse(await window.__walletRpc(JSON.stringify({ method, params: params || [] })));
      if (r.error) { const e = new Error(r.error.message); e.code = r.error.code; if (r.error.data) e.data = r.error.data; throw e; }
      if (method === "eth_requestAccounts") setTimeout(() => emit("accountsChanged", r.result), 0);
      return r.result;
    },
    on(ev, f) { (listeners[ev] = listeners[ev] || []).push(f); return provider; },
    removeListener(ev, f) { listeners[ev] = (listeners[ev] || []).filter((g) => g !== f); return provider; },
  };
  window.__testWallet = { emit };
  try { if (!localStorage.getItem("imd_acc_network")) localStorage.setItem("imd_acc_network", "sepolia"); } catch (e) {} // the checks run against Sepolia
  if (!window.ethereum) window.ethereum = provider; // sites that read window.ethereum, like MetaMask and Rabby set it
  const info = Object.freeze({ uuid: "7e57c0de-0000-4000-8000-000000000001", name: "Test Wallet", rdns: "test.wallet",
    icon: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='8' height='8'/%3E" });
  const announce = () => window.dispatchEvent(new CustomEvent("eip6963:announceProvider", { detail: Object.freeze({ info, provider }) }));
  window.addEventListener("eip6963:requestProvider", announce);
  announce();
})();`;

// opts: { width, height, theme: "light"|"dark", fork: bool, wallet: bool, rejectNext: fn }
export async function newPage(browser, opts = {}) {
  const context = await browser.newContext({
    viewport: { width: opts.width || 1280, height: opts.height || 900 },
    colorScheme: opts.theme || "light",
    reducedMotion: "reduce",
  });
  const page = await context.newPage();
  const log = { errors: [], failed: [], rpcCalls: 0, txs: [], methods: {} };
  page.on("pageerror", (e) => log.errors.push(`pageerror: ${e.message}`));
  page.on("console", (m) => { if (m.type() === "error") log.errors.push(`console: ${m.text()}`); });
  page.on("requestfailed", (r) => log.failed.push(`${r.url()} ${r.failure()?.errorText}`));
  if (opts.fork) {
    await context.route(RPC_HOSTS, async (route) => {
      const req = route.request();
      const cors = { "access-control-allow-origin": "*", "access-control-allow-headers": "*", "access-control-allow-methods": "POST, OPTIONS" };
      if (req.method() === "OPTIONS") return route.fulfill({ status: 204, headers: cors });
      log.rpcCalls++;
      try { const b = JSON.parse(req.postData() || "{}"); for (const c of [].concat(b)) { log.methods[c.method] = (log.methods[c.method] || 0) + 1; } } catch (e) {}
      try {
        const r = await fetch(ANVIL, { method: "POST", headers: { "content-type": "application/json" }, body: req.postData() });
        return route.fulfill({ status: r.status, headers: { ...cors, "content-type": "application/json" }, body: await r.text() });
      } catch (e) {
        return route.abort();
      }
    });
  }
  if (opts.wallet) {
    await page.exposeFunction("__walletRpc", async (s) => {
      const { method, params } = JSON.parse(s);
      try {
        switch (method) {
          case "eth_requestAccounts":
          case "eth_accounts":
            return JSON.stringify({ result: [ACCOUNT] });
          case "eth_chainId":
            return JSON.stringify({ result: "0xaa36a7" });
          case "net_version":
            return JSON.stringify({ result: "11155111" });
          case "wallet_switchEthereumChain":
          case "wallet_addEthereumChain":
            return JSON.stringify({ result: null });
          case "wallet_requestPermissions":
          case "wallet_getPermissions":
            return JSON.stringify({ result: [{ parentCapability: "eth_accounts" }] });
          case "eth_sendTransaction": {
            if (opts.rejectNext && opts.rejectNext()) return JSON.stringify({ error: { code: 4001, message: "User rejected the request." } });
            const tx = { ...params[0], from: ACCOUNT };
            let est = null;
            try { const { gas, ...q } = tx; est = await anvil("eth_estimateGas", [q]); } catch (e) {}
            const r = await fetch(ANVIL, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: [tx] }) });
            const j = await r.json();
            if (j.result) log.txs.push({ hash: j.result, to: tx.to, data: (tx.data || tx.input || "").slice(0, 10), gas: tx.gas && Number(tx.gas), est: est && Number(est), ratio: tx.gas && est ? +(Number(tx.gas) / Number(est)).toFixed(3) : null });
            return JSON.stringify(j);
          }
          default: {
            const r = await fetch(ANVIL, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
            return JSON.stringify(await r.json());
          }
        }
      } catch (e) {
        return JSON.stringify({ error: { code: -32603, message: String(e) } });
      }
    });
    await page.addInitScript(WALLET_INIT);
  }
  return { context, page, log };
}

// Layout facts for the page as it is now.
export async function measure(page) {
  return page.evaluate(() => {
    const vw = document.documentElement.clientWidth;
    const out = { vw, scrollWidth: document.documentElement.scrollWidth, title: document.title };
    const h1 = document.querySelector("main h1, h1");
    out.h1 = h1 ? h1.textContent.trim().slice(0, 80) : null;
    out.h1Count = [...document.querySelectorAll("h1")].filter((e) => e.offsetParent !== null).length;
    out.focusTag = document.activeElement ? document.activeElement.tagName + (document.activeElement.textContent || "").trim().slice(0, 30) : null;
    const bar = document.querySelector("header");
    out.barHeight = bar ? Math.round(bar.getBoundingClientRect().height) : null;
    // Text sizes of visible text nodes.
    const sizes = new Set();
    let tooSmall = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const n = walker.currentNode;
      if (!n.textContent.trim()) continue;
      const el = n.parentElement;
      if (!el || el.closest("[hidden], script, style, noscript")) continue;
      const cs = getComputedStyle(el);
      if (cs.display === "none" || cs.visibility === "hidden") continue;
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) continue;
      const fs = parseFloat(cs.fontSize);
      sizes.add(fs);
      if (fs < 11) tooSmall.push(`${fs}px "${n.textContent.trim().slice(0, 30)}"`);
    }
    out.fontSizes = [...sizes].sort((a, b) => a - b);
    out.tooSmall = tooSmall.slice(0, 5);
    // Elements poking out of the viewport, not inside a scroll box.
    const overflow = [];
    for (const el of document.body.querySelectorAll("*")) {
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.right <= vw + 1) continue;
      let p = el.parentElement, clipped = false;
      while (p && p !== document.body) {
        const cs = getComputedStyle(p);
        if (/(auto|scroll|hidden|clip)/.test(cs.overflowX)) { clipped = true; break; }
        p = p.parentElement;
      }
      if (!clipped) overflow.push(`${el.tagName.toLowerCase()}.${el.className}`.slice(0, 60));
    }
    out.overflow = overflow.slice(0, 5);
    out.fonts = [...document.fonts].filter((f) => f.status !== "unloaded").map((f) => `${f.family.replace(/"/g, "")} ${f.weight} ${f.status}`);
    out.dataBlock = (document.body.innerText.match(/block\s+[\d,]{6,}/i) || [null])[0];
    return out;
  });
}

export async function axe(page) {
  await page.addScriptTag({ content: AXE });
  return page.evaluate(async () => {
    const r = await window.axe.run(document, { runOnly: { type: "tag", values: ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"] } });
    return r.violations.map((v) => `${v.id} (${v.impact}): ${v.nodes.length} node(s) e.g. ${v.nodes[0]?.target?.join(" ")}`);
  });
}
