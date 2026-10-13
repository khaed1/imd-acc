// The Robinhood Chain pages on a local fork, through the site with the injected test wallet:
// Your Stack's "Flush my cashback now" and an application from the Apply page. The wallet starts
// without Robinhood Chain (it answers 4902), so the site has to add the chain first. Nothing is sent
// to Robinhood Chain itself: every RPC host and the wallet are routed to anvil.
// usage: anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8546 --silent &
//        ANVIL=http://127.0.0.1:8546 NETWORK=robinhood ACCOUNT=0x4b91078b2374c956a65f7af0999cae0a935e6821 \
//        SITE=http://127.0.0.1:8787/ node robinhood-fork.mjs
// ACCOUNT should hold Robinhood Chain IMD and have cashback waiting (the test wallet does). The
// application is for the RemoteStacker itself, a contract without an owner(), so anyone may apply
// for it on the fork; it only exercises the page.
import { ACCOUNT, NETWORK, anvil, launch, newPage, prepareAccount } from "./lib.mjs";

const SITE = process.env.SITE || "http://127.0.0.1:8787/";
const RS = "0x4de07c2fa46d5d6ed9ceb3f38ec56d3461b3e898";
const REGISTRY = "0x814da7f2469e3e37158ab7e031a31b3004d9bca1";
const pad = (a) => a.slice(2).toLowerCase().padStart(64, "0");
const call = async (to, data) => BigInt(await anvil("eth_call", [{ to, data }, "latest"]));
const waiting = () => call(RS, "0xe437786d" + pad(ACCOUNT));
if (NETWORK !== "robinhood") throw new Error("run with NETWORK=robinhood");
if ((await anvil("eth_chainId")) !== "0x1237") throw new Error("ANVIL is not a Robinhood Chain fork");

let fails = 0;
const check = (ok, what) => { console.log(`${ok ? "PASS" : "FAIL"} ${what}`); if (!ok) fails++; };
await prepareAccount();
const browser = await launch();
const { page, log } = await newPage(browser, { fork: true, wallet: true, unknownChain: true });
const ready = async () => { for (let i = 0; i < 90; i++) { if (/Data at block/i.test(await page.locator("body").innerText())) return; await page.waitForTimeout(500); } };
const txsAfter = async (n) => { for (let i = 0; i < 120 && log.txs.length < n; i++) await page.waitForTimeout(250); await page.waitForTimeout(4000); };

// 1. Flush from Your Stack.
const before = await waiting();
await page.goto(SITE + "#/stack", { waitUntil: "domcontentloaded" });
await ready();
await page.click("#btn-wallet");
await page.waitForTimeout(3000);
const card = await page.locator(".tool-card").first().innerText();
check(/Bridge fee: [\d.]+ ETH/.test(card) && before > 0n, `the flush card quotes the bridge fee (waiting ${before} wei)`);
await page.click("#btn-flush");
await txsAfter(1);
check(log.walletMethods.includes("wallet_addEthereumChain"), "the wallet didn't know Robinhood Chain: the site added it");
check(log.txs[0] && log.txs[0].data === "0x48897c52", "flush([wallet]) sent");
const receipt = log.txs[0] && (await anvil("eth_getTransactionReceipt", [log.txs[0].hash]));
check(receipt && receipt.status === "0x1", "the flush confirmed on the fork");
const after = await waiting();
check(after < before && after < 10n ** 12n, `waiting ${before} -> ${after} (only sub-step dust may stay)`);
await page.waitForTimeout(3000);
const stack = (await page.locator("#app-root").innerText()).replace(/\s+/g, " ");
const delivered = (stack.match(/Delivered to Ethereum ([\d.,]+) IMD/i) || [])[1];
check(delivered && Number(delivered.replace(/,/g, "")) >= 1.0012, `Your Stack shows the delivery (Delivered to Ethereum ${delivered} IMD)`);

// 2. An application from the Apply page. The fee is 0.5 IMD: on the fork only, top the account up
// from an IMD holder (the trial venue's pool) when it holds less.
const IMD = "0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127", HOLDER = "0x81d17894b724dcb462bd5585be0792b1b32d19cc";
if ((await call(IMD, "0x70a08231" + pad(ACCOUNT))) < 5n * 10n ** 17n) {
  await anvil("anvil_impersonateAccount", [HOLDER]);
  await anvil("anvil_setBalance", [HOLDER, "0x16345785D8A0000"]);
  await anvil("eth_sendTransaction", [{ from: HOLDER, to: IMD, data: "0xa9059cbb" + pad(ACCOUNT) + (10n ** 17n).toString(16).padStart(64, "0") }]);
  console.log("  fork only: 0.1 IMD moved to the account for the fee");
}
const appliedBefore = (await anvil("eth_getLogs", [{ address: REGISTRY, fromBlock: "0x5377e3c" }])).length;
await page.goto(SITE + "#/apply", { waitUntil: "domcontentloaded" });
await ready();
for (const [id, val] of Object.entries({ project: RS, name: "Fork rehearsal", url: "https://repo.sourcify.dev/4663/0x4De07c2fa46D5d6ED9CEB3f38ec56d3461b3E898", rate: "50", beneficiary: ACCOUNT })) {
  const el = page.locator(`#apply-${id}`);
  await el.fill(val);
  await el.blur();
}
await page.waitForTimeout(2500);
const question = (await page.locator("#apply-question code").textContent()).trim();
check(question.includes("on chain 4663") && question.includes(REGISTRY.toLowerCase()), "the registry's own question names chain 4663 and the Robinhood registry");
await page.click("#btn-approve-fee");
await txsAfter(2);
await page.click("#btn-apply-listing");
await txsAfter(3);
console.log("  page:", (await page.locator("#step-apply-disabled").innerText()).trim(), "| toast:", (await page.locator("#toast-text").textContent().catch(() => "")) || "");
const logs = await anvil("eth_getLogs", [{ address: REGISTRY, fromBlock: "0x5377e3c" }]);
check(logs.length > appliedBefore && logs.some((l) => l.topics[0].startsWith("0xb7e8095d")), "Applied emitted by the Robinhood registry on the fork");
check(/Applied/.test(await page.locator("#step-apply-disabled").innerText()), "the page confirms the application");

const errs = log.errors.filter((e) => !/Failed to load resource|net::ERR/.test(e));
check(!errs.length, `no page errors${errs.length ? ": " + errs.slice(0, 3).join(" | ") : ""}`);
for (const t of log.txs) console.log(`TX ${t.data} ${t.hash} gas ${t.gas} (estimate ${t.est})`);
await browser.close();
console.log(fails ? `${fails} FAILED` : "ALL PASS");
process.exit(fails ? 1 : 0);
