/**
 * imd/acc - Interactive Web3 Application & Hash SPA Router
 * Rich Modern Web3 Aesthetics with Full Hash Page Routing
 */

(() => {
  'use strict';

  // --- Constants & Addresses (Sepolia test run 5) ---
  const ADDRESSES = {
    SEPOLIA_CHAIN_ID: '0xaa36a7', // 11155111
    STACKER: '0x0457276d7b036818b3eddc1a4a3fceda61e9314d', // test run 2, launch #1294
    PROJECT_REGISTRY: '0x5f63cdead0f5f693b8964d82b56155f55645ccea', // test run 5, launch #1428
    REGISTRY_RUN4: '0xfe4470a42df0e77f7efb1b2e8135134a9cd7d102', // launch #1378, rules v2
    REGISTRY_RUN3: '0x9b466d1527322435dc7fdd97bc862b49c177fc2d', // launch #1371
    REGISTRY_RUN2: '0x3a3bfcb65614292b0ec7c62f9e3a5dac003b920e', // launch #1294, rules v1
    STACKER_V1: '0x293c7134ab8f6bf1d8ff44ed806575f8f1baf477', // launch #1129
    TEST_IMD: '0x2b69099e59b05901faa1dd164fabf098bf831e82',
    TEST_SIMD: '0xf9e2eec3b610ec6781f7438ac5fb4bc049d81cc1',
    ORACLE_FEE_TOKEN: '0x44a1cd38474fb1748400e7deb5f8d786cce3f89a',
    INTAKE_V2: '0xa43e6f75ee006411f79ac1c84120606c2330de82',
    MAINNET_IMD: '0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7',
    MAINNET_SIMD: '0x9efa934d9fad4ae28c998a40195646b965a97247',
    MAINNET_STACKER: '0x06909f672301f28a810f78cfe7a754851269f4f0', // launch #1409
    ROBINHOOD_IMD: '0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127'
  };

  // Blocks the live contracts were deployed at: reads start here.
  const DEPLOY_BLOCK = { STACKER: 11891109, REGISTRY: 11899694 };

  // Public Sepolia RPCs (all allow browser calls); tried in order.
  const RPC_URLS = [
    'https://ethereum-sepolia-rpc.publicnode.com',
    'https://rpc.sepolia.ethpandaops.io',
    'https://sepolia.drpc.org'
  ];

  const SEL = {
    credit: '0xef6506db', // credit(address,uint256)
    faucet: '0xde5f72fd',
    approve: '0x095ea7b3',
    allowance: '0xdd62ed3e',
    balanceOf: '0x70a08231',
    convertToAssets: '0x07a2d13a',
    paused: '0x5c975abb',
    mint: '0x40c10f19',
    ORACLE_FEE: '0x31d8a985',
    challengeBond: '0x52305151',
    challengeCooldown: '0x55631f9c',
    projectOf: '0x176309b7',
    applyListing: '0x4f604d26', // applyListing(address,string,string,uint16,address)
    challengeForBeneficiary: '0x55b2aebb', // challengeForBeneficiary(address,string,address)
    applyQuestion: '0x7cb9ece7',
    projectOwner: '0x0dd64ae4', // projectOwner(address), test run 5 on
    bondOwed: '0x8af92a6d',
    claimBond: '0x0f022812',
    expire: '0xc8db233e'
  };

  const TOPIC = {
    Stacked: '0x7fbd7b0bc9aac1aa6f42ea64666fad17288ea759411a11f4231a958bc31838c6',
    Applied: '0xb7e8095de4cf7043336c1e0ece05439714eb277c7cb5deed1b4f2479e4a6d173',
    Listed: '0x518fc40ea95a380fb5f45f1ad72398fdefb809c6dfebc59d2236045bd1d10267',
    Rejected: '0xf8a1bb90febbb3cd262033228521e367e8bba1bc6c61eee6bcfa744fafb31f4a',
    Challenged: '0x43993779a041d6ad7d4dceb299983e61e87565d974db929ff04933734959cd0e',
    Defended: '0x42d2c8660fea33f766be7cfab644ef179a97c26621566727cbcb6ae7986963a9',
    Delisted: '0x0f4e3ebc43292a7ecf57e30d244481c276bb21cb84f14905ce5786ddcfe2908a',
    AskCleared: '0x479ec138af9f4c82591accadecba9be18b659e2389b0629555e011f33a6b97d4',
    BeneficiarySet: '0x2906d223dc4163733bb374af8641c7e9ae256e2bae53c90e0c9a2be2e611ae44'
  };

  // Contracts that credit through the Stacker without (yet) a registry application.
  const KNOWN_NAMES = {
    '0x2d5a03d5bab98a4a435edad11813373963bca8cc': 'PLEA (hook)',
    '0x3d1778be5f9e55f0df35acaf64a13efe2fe81488': 'SelfCredit (trial)'
  };

  const ASK_NAMES = ['None', 'Application', 'Challenge'];
  const MAX_UINT = 'f'.repeat(64);

  // --- State ---
  let themeSaved = null;
  try { themeSaved = localStorage.getItem('imd_acc_theme'); } catch {}
  const state = {
    theme: themeSaved || (matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'),
    account: null,
    busy: false,
    applyForm: {
      project: '',
      name: '',
      url: '',
      rate: '50',
      beneficiary: '',
      errors: {},
      note: '',
      question: ''
    }
  };

  // What Sepolia says: loaded from public RPCs, refreshed after every confirmed transaction.
  const live = {
    status: 'idle', // idle | loading | ready | error
    error: '',
    block: 0,
    time: 0, // the latest block's timestamp
    fetchedAt: 0, // when it was read (ms)
    fee: 0n,
    bond: 0n,
    cooldown: 0n,
    vaultPaused: false,
    stacks: [], // newest first: { project, trader, imd, shares, block, tx }
    projects: new Map(), // address -> registry project and/or Stacker caller
    outcomes: [], // newest first
    wallet: null // { imd, imdAllowance, simd, cashbackValue, feeToken, feeAllowance, bondOwed }
  };

  // --- Utilities ---
  function safe(str) {
    if (str === undefined || str === null) return '';
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  function shortAddr(addr) {
    if (!addr) return '';
    return addr.length > 10 ? `${addr.slice(0, 6)}...${addr.slice(-4)}` : addr;
  }

  let toastTimer = null;
  function showToast(msg) {
    const toast = document.getElementById('toast-msg');
    const txt = document.getElementById('toast-text');
    if (!toast) return;
    if (txt) txt.textContent = msg;
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove('show'), 3600);
  }

  function fmtUnits(value, decimals = 18, dp = 4) {
    let v = BigInt(value);
    const neg = v < 0n;
    if (neg) v = -v;
    const base = 10n ** BigInt(decimals);
    const whole = (v / base).toLocaleString('en-US');
    const frac = (v % base).toString().padStart(decimals, '0').slice(0, dp);
    return `${neg ? '-' : ''}${whole}${dp ? '.' + frac : ''}`;
  }

  function parseUnits(text, decimals = 18) {
    const [w, f = ''] = String(text).trim().split('.');
    if (!/^\d*$/.test(w) || !/^\d*$/.test(f) || (!w && !f)) throw new Error('Enter an amount');
    return BigInt(w || '0') * 10n ** BigInt(decimals) + BigInt((f + '0'.repeat(decimals)).slice(0, decimals) || '0');
  }

  function fmtDuration(seconds) {
    const s = Number(seconds);
    if (s % 86400 === 0) return `${s / 86400} day${s === 86400 ? '' : 's'}`;
    if (s % 3600 === 0) return `${s / 3600} hour${s === 3600 ? '' : 's'}`;
    if (s % 60 === 0) return `${s / 60} min`;
    return `${s} s`;
  }

  // The chain's clock (the latest block's time, moved on since it was read), not the visitor's.
  function chainNow() {
    if (!live.time) return Math.floor(Date.now() / 1000);
    return live.time + Math.floor((Date.now() - live.fetchedAt) / 1000);
  }

  function fmtAgo(unixSeconds) {
    const d = Math.max(0, chainNow() - Number(unixSeconds));
    if (d < 60) return 'just now';
    if (d < 3600) return `${Math.floor(d / 60)} min ago`;
    if (d < 86400) return `${Math.floor(d / 3600)} h ago`;
    return `${Math.floor(d / 86400)} d ago`;
  }

  function blockText() {
    if (live.status === 'ready') return `Data at block ${live.block.toLocaleString('en-US')}`;
    if (live.status === 'error') return 'Sepolia data unavailable';
    return 'Loading Sepolia data';
  }

  function txLink(hash, label) {
    return `<a class="mono" href="https://sepolia.etherscan.io/tx/${hash}" target="_blank" rel="noopener noreferrer">${label}</a>`;
  }

  function addrLink(addr) {
    return `<a class="mono" href="https://sepolia.etherscan.io/address/${addr}" target="_blank" rel="noopener noreferrer">${shortAddr(addr)}</a>`;
  }

  // --- ABI encoding and decoding (only the types the site needs) ---
  const pad64 = (hex) => hex.replace(/^0x/, '').toLowerCase().padStart(64, '0');
  const encAddress = (a) => pad64(a);
  const encUint = (n) => pad64(BigInt(n).toString(16));

  function encString(str) {
    const hex = [...new TextEncoder().encode(str)].map(b => b.toString(16).padStart(2, '0')).join('');
    return encUint(hex.length / 2) + hex.padEnd(Math.ceil(hex.length / 64) * 64, '0');
  }

  // args: [type, value] with type 'address' | 'uint' | 'string'
  function encodeCall(selector, args = []) {
    let head = '';
    let tail = '';
    for (const [type, value] of args) {
      if (type === 'string') {
        head += encUint(args.length * 32 + tail.length / 2);
        tail += encString(value);
      } else if (type === 'address') {
        head += encAddress(value);
      } else {
        head += encUint(value);
      }
    }
    return selector + head + tail;
  }

  function words(hex) {
    const h = (hex || '').replace(/^0x/, '');
    const out = [];
    for (let i = 0; i < h.length; i += 64) out.push(h.slice(i, i + 64));
    return out;
  }

  const decUint = (w) => BigInt('0x' + (w || '0'));
  const decAddress = (w) => '0x' + (w || '').slice(24);
  const topicAddress = (t) => '0x' + t.slice(26).toLowerCase();

  function decString(hex, offsetBytes) {
    const h = (hex || '').replace(/^0x/, '');
    const start = offsetBytes * 2;
    const len = Number(decUint(h.slice(start, start + 64)));
    const body = h.slice(start + 64, start + 64 + len * 2);
    return new TextDecoder().decode(new Uint8Array((body.match(/../g) || []).map(x => parseInt(x, 16))));
  }

  function decBytes32Text(w) {
    const bytes = (w.match(/../g) || []).map(x => parseInt(x, 16)).filter(b => b !== 0);
    return new TextDecoder().decode(new Uint8Array(bytes));
  }

  // --- Sepolia reads ---
  async function rpc(method, params) {
    let lastError = null;
    for (const url of RPC_URLS) {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 12000);
      try {
        const res = await fetch(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
          signal: ctrl.signal
        });
        const body = await res.json();
        if (body.error) {
          const err = new Error(body.error.message || 'RPC error');
          err.rpc = true;
          throw err;
        }
        return body.result;
      } catch (e) {
        lastError = e;
        if (e.rpc && method === 'eth_call') throw e; // a revert is the same on every RPC
      } finally {
        clearTimeout(timer);
      }
    }
    throw lastError || new Error('No Sepolia RPC answered');
  }

  const ethCall = (to, data) => rpc('eth_call', [{ to, data }, 'latest']);

  async function getLogs(address, topics, fromBlock, toBlock) {
    const out = [];
    const STEP = 10000;
    for (let a = fromBlock; a <= toBlock; a += STEP) {
      const b = Math.min(toBlock, a + STEP - 1);
      const logs = await rpc('eth_getLogs', [{
        address,
        topics,
        fromBlock: '0x' + a.toString(16),
        toBlock: '0x' + b.toString(16)
      }]);
      out.push(...logs);
    }
    return out;
  }

  function decodeRecord(ret) {
    const w = words(ret);
    return {
      ask: Number(decUint(w[0])),
      listed: decUint(w[1]) === 1n,
      rateBps: Number(decUint(w[2])),
      askedAt: Number(decUint(w[3])),
      fromBlock: Number(decUint(w[4])),
      toBlock: Number(decUint(w[5])),
      beneficiary: decAddress(w[6]),
      challengeOpenAt: Number(decUint(w[7])),
      asker: decAddress(w[8])
    };
  }

  function projectEntry(addr) {
    const key = addr.toLowerCase();
    if (!live.projects.has(key)) {
      live.projects.set(key, {
        address: key,
        name: KNOWN_NAMES[key] || '',
        url: '',
        rateBps: 0,
        applicant: '',
        history: [],
        periods: [],
        stacked: 0n,
        traders: new Set(),
        thirdPartyStacks: 0,
        inRegistry: false,
        record: null
      });
    }
    return live.projects.get(key);
  }

  function isListedAt(project, block) {
    const p = live.projects.get(project.toLowerCase());
    return !!p && p.periods.some(r => block >= r.from && (r.to === null || block < r.to));
  }

  function projectState(p) {
    const r = p.record;
    if (!p.inRegistry || !r) return { label: 'Not applied', cls: 'pill-test' };
    if (r.ask === 1) return { label: 'Applied', cls: 'pill-planned' };
    if (r.ask === 2) return { label: 'Challenged', cls: 'pill-planned' };
    if (r.listed) return { label: 'Listed', cls: 'pill-live' };
    const last = p.history[p.history.length - 1];
    if (last && last.kind === 'Delisted') return { label: 'Delisted', cls: 'pill-test' };
    if (last && last.kind === 'Rejected') return { label: 'Rejected', cls: 'pill-test' };
    return { label: 'Not listed', cls: 'pill-test' };
  }

  let loadPromise = null;
  function loadLive() {
    if (!loadPromise) {
      loadPromise = doLoadLive().finally(() => { loadPromise = null; });
    }
    return loadPromise;
  }

  async function doLoadLive() {
    live.status = live.block ? live.status : 'loading';
    try {
      const latest = await rpc('eth_getBlockByNumber', ['latest', false]);
      const block = Number(latest.number);
      const [fee, bond, cooldown, paused, stackLogs, regLogs] = await Promise.all([
        ethCall(ADDRESSES.PROJECT_REGISTRY, SEL.ORACLE_FEE),
        ethCall(ADDRESSES.PROJECT_REGISTRY, SEL.challengeBond),
        ethCall(ADDRESSES.PROJECT_REGISTRY, SEL.challengeCooldown),
        ethCall(ADDRESSES.TEST_SIMD, SEL.paused),
        getLogs(ADDRESSES.STACKER, [TOPIC.Stacked], DEPLOY_BLOCK.STACKER, block),
        getLogs(ADDRESSES.PROJECT_REGISTRY, [], DEPLOY_BLOCK.REGISTRY, block)
      ]);

      live.projects = new Map();
      live.outcomes = [];

      for (const log of regLogs) {
        const t = log.topics;
        if (!t[1]) continue;
        const kind = Object.keys(TOPIC).find(k => TOPIC[k] === t[0]);
        if (!kind || kind === 'Stacked') continue;
        const p = projectEntry(topicAddress(t[1]));
        p.inRegistry = true;
        const w = words(log.data);
        const blk = Number(log.blockNumber);
        const entry = { kind, block: blk, tx: log.transactionHash, detail: '' };
        if (kind === 'Applied') {
          p.rateBps = Number(decUint(w[0]));
          p.name = decString(log.data, Number(decUint(w[2]))) || p.name;
          p.url = decString(log.data, Number(decUint(w[3])));
          p.applicant = topicAddress(t[2]);
          entry.detail = `${p.rateBps} bps, by ${shortAddr(p.applicant)}`;
        } else if (kind === 'Listed') {
          p.periods.push({ from: blk, to: null });
          entry.detail = `${Number(decUint(w[0]))} bps`;
        } else if (kind === 'Delisted') {
          const open = p.periods.find(r => r.to === null);
          if (open) open.to = blk;
        } else if (kind === 'Challenged') {
          entry.detail = `by ${shortAddr(topicAddress(t[2]))}: ${decString(log.data, Number(decUint(w[0])))}`;
        } else if (kind === 'Defended') {
          entry.detail = `bond ${fmtUnits(decUint(w[0]), 18, 2)} test IMD to the beneficiary`;
        } else if (kind === 'AskCleared') {
          entry.detail = `${ASK_NAMES[Number(decUint(w[0]))] || 'Question'} cleared: ${decBytes32Text(w[2]) || 'no answer'}`;
        } else if (kind === 'BeneficiarySet') {
          entry.detail = `to ${shortAddr(decAddress(w[0]))}`;
        }
        p.history.push(entry);
        if (['Listed', 'Rejected', 'Defended', 'Delisted', 'AskCleared'].includes(kind)) {
          live.outcomes.unshift({ ...entry, project: p.address });
        }
      }

      live.stacks = stackLogs.map(log => {
        const w = words(log.data);
        return {
          project: topicAddress(log.topics[1]),
          trader: topicAddress(log.topics[2]),
          imd: decUint(w[0]),
          shares: decUint(w[1]),
          block: Number(log.blockNumber),
          tx: log.transactionHash
        };
      }).reverse();

      for (const s of live.stacks) {
        const p = projectEntry(s.project);
        p.stacked += s.imd;
        p.traders.add(s.trader);
        if (s.project !== s.trader) p.thirdPartyStacks++;
      }

      const registryProjects = [...live.projects.values()].filter(p => p.inRegistry);
      const records = await Promise.all(registryProjects.map(p =>
        ethCall(ADDRESSES.PROJECT_REGISTRY, encodeCall(SEL.projectOf, [['address', p.address]]))));
      registryProjects.forEach((p, i) => { p.record = decodeRecord(records[i]); });

      live.block = block;
      live.time = Number(latest.timestamp);
      live.fetchedAt = Date.now();
      live.fee = decUint(words(fee)[0]);
      live.bond = decUint(words(bond)[0]);
      live.cooldown = decUint(words(cooldown)[0]);
      live.vaultPaused = decUint(words(paused)[0]) === 1n;
      live.status = 'ready';
      live.error = '';
    } catch (e) {
      if (!live.block) live.status = 'error';
      live.error = e.message || String(e);
    }
  }

  async function loadWallet() {
    const a = state.account;
    if (!a) {
      live.wallet = null;
      return;
    }
    try {
      const mine = live.stacks.filter(s => s.trader === a.toLowerCase());
      const shares = mine.reduce((sum, s) => sum + s.shares, 0n);
      const [imd, imdAllowance, simd, value, feeToken, feeAllowance, owed] = await Promise.all([
        ethCall(ADDRESSES.TEST_IMD, encodeCall(SEL.balanceOf, [['address', a]])),
        ethCall(ADDRESSES.TEST_IMD, encodeCall(SEL.allowance, [['address', a], ['address', ADDRESSES.STACKER]])),
        ethCall(ADDRESSES.TEST_SIMD, encodeCall(SEL.balanceOf, [['address', a]])),
        ethCall(ADDRESSES.TEST_SIMD, encodeCall(SEL.convertToAssets, [['uint', shares]])),
        ethCall(ADDRESSES.ORACLE_FEE_TOKEN, encodeCall(SEL.balanceOf, [['address', a]])),
        ethCall(ADDRESSES.ORACLE_FEE_TOKEN, encodeCall(SEL.allowance, [['address', a], ['address', ADDRESSES.PROJECT_REGISTRY]])),
        ethCall(ADDRESSES.PROJECT_REGISTRY, encodeCall(SEL.bondOwed, [['address', a]]))
      ]);
      const first = (hex) => decUint(words(hex)[0]);
      live.wallet = {
        imd: first(imd),
        imdAllowance: first(imdAllowance),
        simd: first(simd),
        cashbackValue: first(value),
        feeToken: first(feeToken),
        feeAllowance: first(feeAllowance),
        bondOwed: first(owed)
      };
    } catch (e) {
      live.wallet = null;
    }
  }

  // Re-draw the current page with fresh data, keeping the scroll position. An automatic refresh
  // doesn't re-draw while someone is typing in a field; the next one will.
  async function refreshLive(auto = false) {
    await loadLive();
    await loadWallet();
    const el = document.activeElement;
    if (auto && el && /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)) return;
    render(true);
  }

  // --- Theme Management ---
  function applyTheme(t) {
    state.theme = t;
    document.documentElement.dataset.theme = t;
    try { localStorage.setItem('imd_acc_theme', t); } catch {}

    const icon = document.getElementById('icon-theme');
    if (icon) {
      if (t === 'light') {
        icon.innerHTML = `
          <circle cx="12" cy="12" r="5"></circle>
          <line x1="12" y1="1" x2="12" y2="3"></line>
          <line x1="12" y1="21" x2="12" y2="23"></line>
          <line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line>
          <line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line>
          <line x1="1" y1="12" x2="3" y2="12"></line>
          <line x1="21" y1="12" x2="23" y2="12"></line>
          <line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line>
          <line x1="18.36" y1="5.64" x2="19.78" y2="4.22"></line>
        `;
      } else {
        icon.innerHTML = `<path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path>`;
      }
    }
  }

  // --- Wallet transactions (Sepolia, estimate x 1.3) ---
  function walletError(e) {
    if (!e) return 'Transaction failed';
    if (e.code === 4001 || /user (rejected|denied)/i.test(e.message || '')) return 'Rejected in your wallet';
    const msg = e.data?.message || e.message || String(e);
    return msg.length > 160 ? msg.slice(0, 157) + '...' : msg;
  }

  async function connectWallet() {
    if (typeof window.ethereum === 'undefined') {
      throw new Error('No browser wallet found. Install one (MetaMask, Rabby) to use Sepolia.');
    }
    const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
    if (!accounts || !accounts[0]) throw new Error('No account selected');
    setAccount(accounts[0]);
    return state.account;
  }

  async function ensureSepolia() {
    if (!state.account) await connectWallet();
    const chainId = await window.ethereum.request({ method: 'eth_chainId' });
    if (chainId !== ADDRESSES.SEPOLIA_CHAIN_ID) {
      await window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: ADDRESSES.SEPOLIA_CHAIN_ID }]
      });
    }
  }

  async function sendTxWithGas(txParams) {
    const tx = { ...txParams, from: state.account };
    let estimate;
    try {
      estimate = await window.ethereum.request({ method: 'eth_estimateGas', params: [tx] });
    } catch (e) {
      // Sending anyway would only burn gas on a revert.
      throw new Error(`This transaction would fail: ${walletError(e)}`);
    }
    tx.gas = '0x' + Math.ceil(parseInt(estimate, 16) * 1.3).toString(16);
    return window.ethereum.request({ method: 'eth_sendTransaction', params: [tx] });
  }

  async function waitForReceipt(hash) {
    for (let i = 0; i < 60; i++) {
      let receipt = null;
      try {
        receipt = await window.ethereum.request({ method: 'eth_getTransactionReceipt', params: [hash] });
      } catch {}
      if (!receipt) {
        try { receipt = await rpc('eth_getTransactionReceipt', [hash]); } catch {}
      }
      if (receipt) return receipt;
      await new Promise(r => setTimeout(r, 3000));
    }
    throw new Error('Not confirmed after 3 minutes. Check the transaction in your wallet.');
  }

  // Sends one transaction, waits for it, then reloads what Sepolia says.
  async function sendTx(to, data, label) {
    if (state.busy) throw new Error('Another transaction is still running');
    state.busy = true;
    try {
      await ensureSepolia();
      showToast(`${label}: confirm in your wallet`);
      const hash = await sendTxWithGas({ to, data });
      showToast(`${label}: sent, waiting for Sepolia`);
      const receipt = await waitForReceipt(hash);
      if (receipt.status !== '0x1') throw new Error(`${label} failed on chain`);
      showToast(`${label}: confirmed`);
      return receipt;
    } finally {
      state.busy = false;
      refreshLive();
    }
  }

  function setAccount(account) {
    state.account = account ? account.toLowerCase() : null;
    const label = document.getElementById('wallet-label');
    const btn = document.getElementById('btn-wallet');
    if (label) label.textContent = state.account ? shortAddr(state.account) : 'Connect Wallet';
    if (btn) {
      btn.classList.toggle('btn-primary', !!state.account);
      btn.classList.toggle('btn-secondary', !state.account);
    }
  }

  // --- Router & Page Renderers ---
  const appRoot = document.getElementById('app-root');

  function render(keepScroll = false) {
    const rawHash = location.hash || '#/';
    let route = rawHash.replace(/^#/, '');
    if (!route || route === '/') route = '/';

    // Update active nav highlights
    const cleanRoute = route.split('/')[1] || 'home';
    document.querySelectorAll('.nav-link').forEach((link) => {
      const linkRoute = link.getAttribute('data-route');
      if (linkRoute === cleanRoute || (cleanRoute === 'home' && linkRoute === 'home')) {
        link.classList.add('active');
        link.setAttribute('aria-current', 'page');
      } else {
        link.classList.remove('active');
        link.removeAttribute('aria-current');
      }
    });

    // Close mobile nav if open
    const navMenu = document.getElementById('nav-menu');
    if (navMenu) navMenu.classList.remove('open');
    document.getElementById('mobile-toggle')?.setAttribute('aria-expanded', 'false');

    // Route Dispatch
    if (route === '/') {
      renderHome();
    } else if (route === '/stack') {
      renderStack();
    } else if (route === '/calculator') {
      location.replace('#/');
      return;
    } else if (route === '/projects') {
      renderProjects();
    } else if (route.startsWith('/projects/')) {
      const addr = route.slice('/projects/'.length);
      renderProjectDetail(addr);
    } else if (route === '/apply') {
      renderApply();
    } else if (route === '/leaderboard') {
      renderLeaderboard();
    } else if (route === '/contracts') {
      location.replace('#/docs/contracts');
      return;
    } else if (route === '/docs' || route.startsWith('/docs/')) {
      if (keepScroll) return; // the docs don't change with chain data
      renderDocs(route.slice('/docs/'.length) || 'introduction');
    } else {
      renderNotFound();
    }

    // Scroll cleanly to top on navigation (without triggering artificial focus outlines)
    if (!keepScroll) window.scrollTo({ top: 0, behavior: 'instant' });
    initCommonListeners();
  }

  // --- Page: Overview / Home (#/) ---
  function renderHome() {
    document.title = 'imd/acc · Trading Cashback in Staked IMD';

    appRoot.innerHTML = `
      <div class="page-view">
        <section class="hero-section">
          <div class="hero-pill">
            <span class="hero-pill-dot"></span>
            <span>Zero-Custody Trading Cashback</span>
          </div>
          <h1 class="hero-title">
            Every Trade Stacks <span class="gradient-text">Staked IMD</span> For You.
          </h1>
          <p class="hero-desc">
            Participating projects send <strong>0.25% to 1%</strong> of each trade straight to your wallet as sIMD shares in IMD's staking vault. No extra fee, no claiming, and it earns continuous yield.
          </p>

          <div class="hero-actions">
            <a href="#/stack" class="btn btn-primary">
              <span>Launch App & Stack</span>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="5" y1="12" x2="19" y2="12"></line><polyline points="12 5 19 12 12 19"></polyline></svg>
            </a>
            <a href="#/docs" class="btn btn-secondary">
              <span>Read the Docs</span>
            </a>
            <a href="#/projects" class="btn btn-secondary">
              <span>View Projects</span>
            </a>
          </div>

          <!-- 4 Core Pillars -->
          <div class="pillars-grid">
            <div class="pillar-card">
              <div class="pillar-header">
                <h3 class="pillar-title">No New Token</h3>
              </div>
              <p class="pillar-desc">The cashback is pure IMD, staked. There is nothing speculative to buy or manage.</p>
            </div>

            <div class="pillar-card">
              <div class="pillar-header">
                <h3 class="pillar-title">Zero Custody</h3>
              </div>
              <p class="pillar-desc">imd/acc never holds your tokens. The ERC-4626 vault mints shares directly to your wallet.</p>
            </div>

            <div class="pillar-card">
              <div class="pillar-header">
                <h3 class="pillar-title">No Extra Fee</h3>
              </div>
              <p class="pillar-desc">Projects pay cashback out of fees they already charge. Traders pay nothing extra on top.</p>
            </div>

            <div class="pillar-card">
              <div class="pillar-header">
                <h3 class="pillar-title">Ownerless Contract</h3>
              </div>
              <p class="pillar-desc">The Stacker contract has no admin, no pause, no fee take, and immutable parameters.</p>
            </div>
          </div>

          <!-- Animated Architecture Pipeline -->
          <div class="flow-diagram-container">
            <div class="diagram-header">
              <h3 class="diagram-title">How Cashback Moves in a Single Transaction</h3>
              <p class="diagram-subtitle">From swap hook directly into your vault balance in the same atomic block</p>
            </div>

            <div class="pipeline-steps">
              <div class="pipeline-step">
                <span class="step-num">1</span>
                <h4 class="step-title">Trader Swaps</h4>
                <p class="step-desc">Trader executes a trade in a participating Uniswap v4 pool (e.g. PLEA/IMD).</p>
                <div class="step-badge">hookData &rarr; real trader</div>
              </div>

              <div class="pipeline-step">
                <span class="step-num">2</span>
                <h4 class="step-title">Hook Cuts Rate</h4>
                <p class="step-desc">The pool hook extracts 0.25%–1% of the trade on the IMD side out of its regular fee.</p>
                <div class="step-badge">25 to 100 bps</div>
              </div>

              <div class="pipeline-step">
                <span class="step-num">3</span>
                <h4 class="step-title">Stacker.credit()</h4>
                <p class="step-desc">Stacker pulls the IMD from the pool and immediately deposits it into the sIMD vault.</p>
                <div class="step-badge">0 IMD held in transit</div>
              </div>

              <div class="pipeline-step">
                <span class="step-num">4</span>
                <h4 class="step-title">sIMD In Wallet</h4>
                <p class="step-desc">sIMD shares arrive in the trader's wallet, accruing vault yield with 1 pt per IMD.</p>
                <div class="step-badge">Shares & Points live</div>
              </div>
            </div>
          </div>
        </section>

        <!-- Quick Summary Box -->
        <div class="dashboard-card" style="padding: 24px;">
          <div class="card-header-row" style="margin-bottom: 12px;">
            <h3 class="card-title" style="font-size: 1.05rem;">Live Sepolia Network Status</h3>
            <span class="pill pill-live">Test Run 5 Live</span>
          </div>
          <p class="secondary" style="margin-bottom: 16px;">${blockText()} &middot; Stacker (launch #1294) and ProjectRegistry (launch #1428) live${live.status === 'ready' ? `: ${live.stacks.length} cashback credit${live.stacks.length === 1 ? '' : 's'} so far, ${[...live.projects.values()].filter(p => p.record && p.record.listed).length} listed project(s)` : ''}.</p>
          <div style="display: flex; gap: 12px; flex-wrap: wrap;">
            <a href="#/stack" class="btn btn-primary btn-sm">Your Stack Console</a>
            <a href="#/docs" class="btn btn-secondary btn-sm">Read the Docs</a>
            <a href="#/projects" class="btn btn-secondary btn-sm">View Projects</a>
          </div>
        </div>
      </div>
    `;
  }

  // --- Page: Stack & Test Tools (#/stack) ---
  function stackRows(rows, emptyText) {
    if (!rows.length) {
      return `<tr><td colspan="5" class="secondary">${emptyText}</td></tr>`;
    }
    return rows.map(s => {
      const p = live.projects.get(s.project);
      const listed = isListedAt(s.project, s.block);
      return `
        <tr>
          <td><strong class="mono">${s.project === s.trader ? 'Self-stack' : safe(p?.name || shortAddr(s.project))}</strong><div class="secondary" style="font-size: 0.76rem;">${txLink(s.tx, 'block ' + s.block.toLocaleString('en-US'))}</div></td>
          <td class="mono" style="white-space: nowrap;">${fmtUnits(s.imd)} IMD</td>
          <td class="mono" style="white-space: nowrap;">${fmtUnits(s.shares, 24)} sIMD</td>
          <td class="mono">${listed ? fmtUnits(s.imd) : '0.0000'}</td>
          <td><span class="pill ${listed ? 'pill-live' : 'pill-test'}">${listed ? 'Listed' : 'Direct'}</span></td>
        </tr>`;
    }).join('');
  }

  function renderStack() {
    document.title = 'Stack - imd/acc';
    const a = state.account;
    const w = live.wallet;
    const mine = a ? live.stacks.filter(s => s.trader === a) : [];
    const cashback = mine.reduce((t, s) => t + s.imd, 0n);
    const points = mine.reduce((t, s) => t + (isListedAt(s.project, s.block) ? s.imd : 0n), 0n);
    const shown = a ? mine : live.stacks.slice(0, 10);
    const dash = '&mdash;';

    appRoot.innerHTML = `
      <div class="page-view">
        <div class="page-header-block">
          <div class="page-tag"><span class="status-indicator"></span> Sepolia Test Run 5 &middot; ${blockText()}</div>
          <h1 class="page-title">Your Stack & Testnet Console</h1>
          <p class="page-desc">Track accumulated cashback, sIMD vault shares, and use the Sepolia testnet tools.</p>
        </div>

        <div class="app-grid">
          <!-- Stack Dashboard -->
          <div class="dashboard-card">
            <div class="card-header-row">
              <h3 class="card-title">Your Stack Dashboard</h3>
              <div class="badge-status ${a ? 'connected' : 'disconnected'}">
                <span class="status-indicator"></span>
                <span>${a ? `Connected: ${shortAddr(a)}` : 'Connect a wallet to see your stack'}</span>
              </div>
            </div>

            <div class="stats-grid">
              <div class="stat-box">
                <span class="stat-label">Cashback Received</span>
                <span class="stat-val" id="stat-cashback">${a ? fmtUnits(cashback) + ' IMD' : dash}</span>
                <span class="stat-change">${a ? `From ${mine.length} credit${mine.length === 1 ? '' : 's'}` : 'From your Stacked events'}</span>
              </div>

              <div class="stat-box">
                <span class="stat-label">sIMD Shares Held</span>
                <span class="stat-val" id="stat-shares">${w ? fmtUnits(w.simd, 24) + ' sIMD' : dash}</span>
                <span class="stat-change">Live in the TestSIMD vault</span>
              </div>

              <div class="stat-box">
                <span class="stat-label">Current Value</span>
                <span class="stat-val" id="stat-worth">${w ? fmtUnits(w.cashbackValue) + ' IMD' : dash}</span>
                <span class="stat-change">${w ? `+${fmtUnits(w.cashbackValue > cashback ? w.cashbackValue - cashback : 0n)} IMD yield` : 'Your cashback, priced by the vault'}</span>
              </div>

              <div class="stat-box">
                <span class="stat-label">Total Points</span>
                <span class="stat-val" id="stat-points">${a ? fmtUnits(points) + ' PTS' : dash}</span>
                <span class="stat-change">1 PT per IMD from listed projects</span>
              </div>
            </div>

            <h4 style="font-size: 0.95rem; margin-bottom: 12px;">${a ? 'Your Cashback Events' : 'Recent Cashback Events (all traders)'}</h4>
            <div class="projects-table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Project</th>
                    <th>Cashback</th>
                    <th>Shares</th>
                    <th>Points</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody id="events-table-body">
                  ${live.status === 'ready'
                    ? stackRows(shown, a ? 'No cashback for this wallet yet. Try "Stack to myself".' : 'No cashback credited yet.')
                    : `<tr><td colspan="5" class="secondary">${blockText()}</td></tr>`}
                </tbody>
              </table>
            </div>
          </div>

          <!-- Test Tools -->
          <div class="test-tools-box">
            <div class="tool-card">
              <h4 class="tool-title">Sepolia Test IMD Faucet</h4>
              <p class="tool-desc">Request 10,000 TestIMD per address every 24 hours to test trades and crediting.${w ? ` You hold <span class="mono">${fmtUnits(w.imd, 18, 2)}</span> tIMD.` : ''}</p>
              <button class="btn btn-primary btn-sm" id="btn-faucet" style="width: 100%;">
                <span>Request 10,000 TestIMD</span>
              </button>
            </div>

            <div class="tool-card">
              <h4 class="tool-title">Test "Stack to Myself"</h4>
              <p class="tool-desc">Approve TestIMD and call <code>Stacker.credit(self, amount)</code> to test the vault minting path.</p>
              <div class="tool-input-row" style="margin-bottom: 10px;">
                <input type="number" class="input-text" id="self-stack-amt" value="5" min="0" step="any" placeholder="Amount">
                <button class="btn btn-secondary btn-sm" id="btn-approve-imd">${w && w.imdAllowance > 10n ** 30n ? 'Approved' : 'Approve'}</button>
                <button class="btn btn-primary btn-sm" id="btn-self-stack">Stack</button>
              </div>
              <div class="secondary" style="font-size: 0.78rem;">Self-stacks are direct, no points.</div>
            </div>

            <div class="tool-card" style="background: var(--bg-card);">
              <h4 class="tool-title">Sepolia Verification Status</h4>
              <p class="tool-desc" style="margin-bottom: 8px;">Stacker at block <code>${DEPLOY_BLOCK.STACKER.toLocaleString('en-US')}</code> (launch #1294); ProjectRegistry at block <code>${DEPLOY_BLOCK.REGISTRY.toLocaleString('en-US')}</code> (launch #1428).</p>
              <div style="font-size: 0.8rem; color: var(--text-muted); line-height: 1.5;">
                &bull; Vault status: ${live.status === 'ready'
                  ? `<span style="color: ${live.vaultPaused ? 'var(--status-pending)' : 'var(--status-live)'};">${live.vaultPaused ? 'Paused (credits revert)' : 'Active (Unpaused)'}</span>`
                  : '<span class="mono">&mdash;</span>'}<br>
                &bull; Oracle fee: <span class="mono">${live.status === 'ready' ? fmtUnits(live.fee, 18, 2) + ' test IMD' : '&mdash;'}</span><br>
                &bull; Challenge bond: <span class="mono">${live.status === 'ready' ? fmtUnits(live.bond, 18, 0) + ' test IMD' : '&mdash;'}</span><br>
                &bull; Cooldown: <span class="mono">${live.status === 'ready' ? fmtDuration(live.cooldown) : '&mdash;'}</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    `;

    document.getElementById('btn-faucet')?.addEventListener('click', async () => {
      try {
        await sendTx(ADDRESSES.TEST_IMD, SEL.faucet, 'Faucet');
      } catch (e) {
        showToast(walletError(e));
      }
    });

    document.getElementById('btn-approve-imd')?.addEventListener('click', async () => {
      try {
        await sendTx(ADDRESSES.TEST_IMD, SEL.approve + encAddress(ADDRESSES.STACKER) + MAX_UINT, 'Approve TestIMD');
      } catch (e) {
        showToast(walletError(e));
      }
    });

    document.getElementById('btn-self-stack')?.addEventListener('click', async () => {
      try {
        const amount = parseUnits(document.getElementById('self-stack-amt')?.value || '0');
        if (amount === 0n) throw new Error('Enter an amount above 0');
        await ensureSepolia();
        await sendTx(ADDRESSES.STACKER, encodeCall(SEL.credit, [['address', state.account], ['uint', amount]]), 'Stack to myself');
      } catch (e) {
        showToast(walletError(e));
      }
    });
  }

  // --- Page: Projects (#/projects) ---
  let activeFilter = 'all';

  // Registry projects, and contracts that credited someone else (not wallets stacking to themselves).
  function allProjects() {
    return [...live.projects.values()].filter(p => p.inRegistry || p.thirdPartyStacks > 0).sort((x, y) =>
      Number(y.inRegistry) - Number(x.inRegistry) || (y.stacked > x.stacked ? 1 : y.stacked < x.stacked ? -1 : 0));
  }

  function renderProjects() {
    document.title = 'Projects - imd/acc';
    const projects = allProjects().filter(p => {
      const st = projectState(p).label;
      if (activeFilter === 'listed') return st === 'Listed';
      if (activeFilter === 'pending') return st === 'Applied' || st === 'Challenged';
      if (activeFilter === 'direct') return !p.inRegistry;
      return true;
    });

    let rows;
    if (live.status !== 'ready') {
      rows = `<tr><td colspan="6" class="secondary">${blockText()}</td></tr>`;
    } else if (!projects.length) {
      rows = `<tr><td colspan="6" class="secondary">No projects here yet. <a href="#/apply" style="color: var(--accent-primary);">Apply for a listing</a>.</td></tr>`;
    } else {
      rows = projects.map(p => {
        const st = projectState(p);
        return `
          <tr style="cursor: pointer;" onclick="location.hash='#/projects/${p.address}'">
            <td>
              <div style="font-weight: 700; color: var(--text-primary);">${safe(p.name || shortAddr(p.address))}</div>
              <div class="secondary mono" style="font-size: 0.76rem;">${shortAddr(p.address)}</div>
            </td>
            <td><span class="mono">Sepolia</span></td>
            <td>${p.rateBps ? `<strong class="mono" style="color: var(--accent-light);">${(p.rateBps / 100).toFixed(2)}% (${p.rateBps} bps)</strong>` : '<span class="secondary">&mdash;</span>'}</td>
            <td class="mono">${fmtUnits(p.stacked, 18, 2)} IMD</td>
            <td><span class="pill ${st.cls}">${st.label}</span></td>
            <td><a href="#/projects/${p.address}" class="btn btn-secondary btn-sm">&rarr; View</a></td>
          </tr>`;
      }).join('');
    }

    appRoot.innerHTML = `
      <div class="page-view">
        <div class="page-header-block">
          <div class="page-tag">Test Run 5 Registry &middot; ${blockText()}</div>
          <h1 class="page-title">Participating Projects</h1>
          <p class="page-desc">Only credits from listed projects earn points. Every project selects its rate between 0.25% and 1.0%.</p>
        </div>

        <div class="filter-tabs">
          <button class="filter-tab ${activeFilter === 'all' ? 'active' : ''}" data-filter="all">All Projects</button>
          <button class="filter-tab ${activeFilter === 'listed' ? 'active' : ''}" data-filter="listed">Listed</button>
          <button class="filter-tab ${activeFilter === 'pending' ? 'active' : ''}" data-filter="pending">Open Questions</button>
          <button class="filter-tab ${activeFilter === 'direct' ? 'active' : ''}" data-filter="direct">Not Applied</button>
        </div>

        <div class="projects-table-wrap">
          <table class="data-table">
            <thead>
              <tr>
                <th>Project</th>
                <th>Chain</th>
                <th>Cashback Rate</th>
                <th>IMD Stacked</th>
                <th>Registry Status</th>
                <th>Details</th>
              </tr>
            </thead>
            <tbody>${rows}</tbody>
          </table>
        </div>
        <p class="secondary" style="font-size: 0.84rem;">Projects come from the test run 5 ProjectRegistry (<span class="mono">${shortAddr(ADDRESSES.PROJECT_REGISTRY)}</span>) and from contracts that credit through the Stacker. Planned: PLEA on Ethereum mainnet, and PondPad on Robinhood Chain through the <a href="#/docs/multichain" style="color: var(--accent-primary);">multichain route</a>.</p>
      </div>
    `;

    document.querySelectorAll('.filter-tab').forEach(btn => {
      btn.addEventListener('click', (e) => {
        activeFilter = e.currentTarget.getAttribute('data-filter');
        renderProjects();
      });
    });
  }

  // --- Page: Project Detail (#/projects/<address>) ---
  function renderProjectDetail(rawAddr) {
    const addr = rawAddr.toLowerCase();
    document.title = `Project ${shortAddr(rawAddr)} - imd/acc`;
    const p = live.projects.get(addr);

    if (!/^0x[0-9a-f]{40}$/.test(addr) || (!p && live.status === 'ready')) {
      appRoot.innerHTML = `
        <div class="page-view">
          <div class="page-header-block">
            <div class="page-tag"><a href="#/projects">&larr; Projects Directory</a></div>
            <h1 class="page-title">Project Not Found</h1>
          </div>
          <div class="dashboard-card">
            <p class="secondary" style="overflow-wrap: anywhere;">Contract <span class="mono">${safe(rawAddr)}</span> has not applied to the test run 5 ProjectRegistry and has no Stacker credits.</p>
            <div style="margin-top: 16px; display: flex; gap: 10px; flex-wrap: wrap;">
              <a href="#/projects" class="btn btn-secondary btn-sm">&larr; Back to Projects</a>
              <a href="#/apply" class="btn btn-primary btn-sm">Apply for Listing</a>
            </div>
          </div>
        </div>
      `;
      return;
    }

    if (!p) {
      appRoot.innerHTML = `
        <div class="page-view">
          <div class="page-header-block">
            <div class="page-tag"><a href="#/projects">&larr; Projects Directory</a></div>
            <h1 class="page-title">${shortAddr(addr)}</h1>
            <p class="page-desc">${blockText()}</p>
          </div>
        </div>
      `;
      return;
    }

    const st = projectState(p);
    const r = p.record;
    const now = chainNow();
    const needed = live.fee + live.bond;
    let challengeBody;
    if (!r || !r.listed) {
      challengeBody = `<p class="secondary">Only listed projects can be challenged. ${p.inRegistry ? '' : 'This contract has not applied to the registry.'}</p>`;
    } else if (r.ask !== 0) {
      challengeBody = `<p class="secondary">A question about this project is open; it can be challenged once it settles.</p>`;
    } else {
      const wait = r.challengeOpenAt > now ? r.challengeOpenAt - now : 0;
      challengeBody = `
        <p class="secondary" style="margin-bottom: 14px;">Anyone can challenge a listed project for the ${fmtUnits(live.fee, 18, 2)} test IMD fee plus a ${fmtUnits(live.bond, 18, 0)} test IMD bond. If the panel says it still meets the rules, the bond goes to its beneficiary; otherwise it is delisted and the bond comes back.</p>
        ${wait ? `<p class="secondary" style="color: var(--status-pending); margin-bottom: 12px;">Cooldown active. Challenge opens in ${fmtDuration(Math.ceil(wait / 60) * 60)}.</p>` : ''}
        <div class="form-group">
          <label class="form-label" for="ch-reason">Reason for Challenge</label>
          <input type="text" id="ch-reason" class="form-input" maxlength="280" placeholder="State reason (max 280 chars)...">
          <div id="ch-reason-error" class="field-error"></div>
        </div>
        <button class="btn btn-secondary btn-sm" id="btn-submit-challenge"${wait ? ' disabled' : ''}>Submit Challenge (${fmtUnits(needed, 18, 1)} test IMD)</button>`;
    }

    const expirable = r && r.ask !== 0 && now > r.askedAt + 86400;
    const periods = p.periods.map(x => `from block ${x.from.toLocaleString('en-US')}${x.to ? ` to ${x.to.toLocaleString('en-US')}` : ' (current)'}`);

    appRoot.innerHTML = `
      <div class="page-view">
        <div class="page-header-block">
          <div class="page-tag"><a href="#/projects">&larr; Projects Directory</a></div>
          <h1 class="page-title">${safe(p.name || shortAddr(p.address))}</h1>
          <p class="page-desc mono" style="font-size: 0.88rem; overflow-wrap: anywhere;">${p.address}</p>
        </div>

        <div class="grid-2">
          <div class="dashboard-card">
            <div class="card-header-row">
              <h3 class="card-title">Project Details</h3>
              <span class="pill ${st.cls}">${st.label}</span>
            </div>
            <p style="margin-bottom: 8px;">Applied rate: ${p.rateBps ? `<strong class="mono" style="color: var(--accent-light);">${(p.rateBps / 100).toFixed(2)}% (${p.rateBps} bps)</strong>` : '<span class="secondary">not applied</span>'}</p>
            <p style="margin-bottom: 8px;">Beneficiary: ${r && r.beneficiary !== '0x0000000000000000000000000000000000000000' ? addrLink(r.beneficiary) : '<span class="secondary">&mdash;</span>'}</p>
            <p style="margin-bottom: 8px;">IMD stacked through it: <span class="mono">${fmtUnits(p.stacked, 18, 4)} IMD</span> (${p.traders.size} trader${p.traders.size === 1 ? '' : 's'})</p>
            <p style="margin-bottom: 8px;">Listing periods: <span class="secondary">${periods.length ? periods.join('; ') : 'none'}</span></p>
            ${p.url ? `<p style="overflow-wrap: anywhere;">Source: <a href="${safe(p.url)}" target="_blank" rel="noopener noreferrer" style="color: var(--accent-primary);">${safe(p.url)}</a></p>` : ''}

            <h4 style="font-size: 0.95rem; margin-top: 20px; margin-bottom: 10px;">Registry Event Log</h4>
            <ul style="list-style: none; display: flex; flex-direction: column; gap: 6px; font-size: 0.85rem;" class="secondary">
              ${p.history.length ? p.history.map(h => `<li>&bull; <strong style="color: var(--text-primary);">${h.kind}</strong> ${safe(h.detail)} &middot; ${txLink(h.tx, 'block ' + h.block.toLocaleString('en-US'))}</li>`).join('') : '<li>No registry events.</li>'}
            </ul>
            ${expirable ? `<button class="btn btn-secondary btn-sm" id="btn-expire" style="margin-top: 16px;">Clear the expired question</button>` : ''}
          </div>

          <div class="dashboard-card">
            <div class="card-header-row">
              <h3 class="card-title">Challenge Listing</h3>
            </div>
            ${challengeBody}
          </div>
        </div>
      </div>
    `;

    document.getElementById('btn-submit-challenge')?.addEventListener('click', async () => {
      const reason = document.getElementById('ch-reason')?.value?.trim() || '';
      const err = document.getElementById('ch-reason-error');
      const textError = checkText(reason, 1, 280, 'reason');
      if (textError) {
        if (err) err.textContent = textError;
        return;
      }
      if (err) err.textContent = '';
      try {
        await ensureSepolia();
        await loadWallet();
        const w = live.wallet;
        if (!w || w.feeToken < needed) throw new Error(`You need ${fmtUnits(needed, 18, 1)} test IMD: use "Get 10 test IMD" on the Apply page`);
        if (w.feeAllowance < needed) {
          await sendTx(ADDRESSES.ORACLE_FEE_TOKEN, SEL.approve + encAddress(ADDRESSES.PROJECT_REGISTRY) + encUint(needed), 'Approve fee and bond');
        }
        await sendTx(ADDRESSES.PROJECT_REGISTRY, encodeCall(SEL.challengeForBeneficiary, [['address', p.address], ['string', reason], ['address', r.beneficiary]]), 'Challenge');
      } catch (e) {
        showToast(walletError(e));
      }
    });

    document.getElementById('btn-expire')?.addEventListener('click', async () => {
      try {
        await sendTx(ADDRESSES.PROJECT_REGISTRY, encodeCall(SEL.expire, [['address', p.address]]), 'Clear question');
      } catch (e) {
        showToast(walletError(e));
      }
    });
  }

  // --- Page: Apply (#/apply) ---
  // The registry's own text rules: printable ASCII without quotes, backslashes or brackets.
  function checkText(val, min, max, what) {
    if (val.length < min) return `${what} is required`;
    if (val.length > max) return `${what} too long (maximum ${max} characters)`;
    if (val.includes('"')) return 'disallowed character: double quote';
    if (val.includes('\\')) return 'disallowed character: backslash';
    if (/[[\]]/.test(val)) return 'disallowed character: square bracket';
    if (/[^\x20-\x7E]/.test(val)) return 'disallowed character: non-ASCII';
    return '';
  }

  function validateApply(id, val) {
    val = (val || '').trim();
    if (id === 'project' || id === 'beneficiary') {
      if (!/^0x[a-fA-F0-9]{40}$/.test(val)) return 'not an address';
      if (/^0x0{40}$/.test(val)) return 'cannot be the zero address';
    }
    if (id === 'name') return checkText(val, 1, 48, 'name');
    if (id === 'url') {
      if (!val.startsWith('https://')) return 'URL must start with https://';
      return checkText(val, 12, 200, 'URL');
    }
    if (id === 'rate') {
      if (!/^\d+$/.test(val) || +val < 25 || +val > 100) return 'rate must be between 25 and 100 bps';
    }
    return '';
  }

  function applyStatus() {
    const w = live.wallet;
    if (!state.account) return 'Connect a wallet on Sepolia to apply.';
    if (!w || live.status !== 'ready') return 'Reading your balance from Sepolia...';
    if (w.feeToken < live.fee) return `You need ${fmtUnits(live.fee, 18, 2)} test IMD for the fee: use "Get 10 test IMD".`;
    if (w.feeAllowance < live.fee) return `Approve the ${fmtUnits(live.fee, 18, 2)} test IMD fee to the registry.`;
    return `Ready: the ${fmtUnits(live.fee, 18, 2)} test IMD fee is approved.`;
  }

  function renderApply() {
    document.title = 'Apply - imd/acc';
    const f = state.applyForm;
    const w = live.wallet;
    const open = allProjects().filter(p => p.record && p.record.ask !== 0);

    appRoot.innerHTML = `
      <div class="page-view">
        <div class="page-header-block">
          <div class="page-tag">Test Run 5 Registry &middot; ${blockText()}</div>
          <h1 class="page-title">Apply for Project Listing</h1>
          <p class="page-desc">List your project on the ownerless ProjectRegistry so your traders' cashback credits earn points.</p>
        </div>

        <div class="app-grid">
          <div class="dashboard-card">
            <h3 class="card-title" style="margin-bottom: 20px;">Application Form</h3>

            <div class="form-group">
              <label class="form-label" for="apply-project">Contract Address</label>
              <input type="text" id="apply-project" class="form-input" value="${safe(f.project)}" placeholder="0x...">
              <div id="apply-project-error" class="field-error">${safe(f.errors.project || '')}</div>
            </div>

            <div class="form-group">
              <label class="form-label" for="apply-name">Project Name (1-48 chars)</label>
              <input type="text" id="apply-name" class="form-input" value="${safe(f.name)}" placeholder="e.g. PLEA">
              <div id="apply-name-error" class="field-error">${safe(f.errors.name || '')}</div>
            </div>

            <div class="form-group">
              <label class="form-label" for="apply-url">Verified Source URL (https://)</label>
              <input type="text" id="apply-url" class="form-input" value="${safe(f.url)}" placeholder="https://repo.sourcify.dev/...">
              <div id="apply-url-error" class="field-error">${safe(f.errors.url || '')}</div>
            </div>

            <div class="form-group">
              <label class="form-label" for="apply-rate">Cashback Rate (25 to 100 bps)</label>
              <input type="number" id="apply-rate" class="form-input" value="${safe(f.rate)}" placeholder="50">
              <div id="apply-rate-error" class="field-error">${safe(f.errors.rate || '')}</div>
            </div>

            <div class="form-group">
              <label class="form-label" for="apply-beneficiary">Beneficiary Address</label>
              <input type="text" id="apply-beneficiary" class="form-input" value="${safe(f.beneficiary)}" placeholder="0x...">
              <div id="apply-beneficiary-error" class="field-error">${safe(f.errors.beneficiary || '')}</div>
            </div>

            <div style="display: flex; gap: 10px; flex-wrap: wrap; margin-top: 20px;">
              <button class="btn btn-secondary btn-sm" id="btn-get-feetoken">Get 10 test IMD</button>
              <button class="btn btn-secondary btn-sm" id="btn-approve-fee">Approve fee</button>
              <button class="btn btn-primary btn-sm" id="btn-apply-listing">Apply for listing</button>
            </div>
            <div id="step-apply-disabled" class="disabled-reason">${safe(f.note || applyStatus())}</div>

            <!-- Panel Preview -->
            <div id="apply-panel" style="margin-top: 24px;">
              <label class="form-label">Oracle Panel Question Preview (read from the registry)</label>
              <div class="code-container" style="margin-top: 6px;">
                <pre class="code-block" id="apply-question" style="font-size: 0.8rem; white-space: pre-wrap; overflow-wrap: anywhere;"><code>${safe(f.question || 'Fill out the application form to read the exact question the registry will ask.')}</code></pre>
              </div>
            </div>
          </div>

          <!-- Open Questions & Recent Outcomes -->
          <div class="test-tools-box">
            <div class="dashboard-card" style="padding: 24px;">
              <h3 class="card-title" style="margin-bottom: 14px;">Open Questions</h3>
              <div style="display: flex; flex-direction: column; gap: 12px;">
                ${live.status !== 'ready' ? `<span class="secondary">${blockText()}</span>` : open.length ? open.map(p => `
                  <div style="border-bottom: 1px solid var(--border-subtle); padding-bottom: 8px;">
                    <a href="#/projects/${p.address}"><strong>${safe(p.name || shortAddr(p.address))}</strong></a> (${ASK_NAMES[p.record.ask]})<br>
                    <span class="secondary mono" style="font-size: 0.78rem;">${shortAddr(p.address)} &middot; ${fmtAgo(p.record.askedAt)}</span>
                  </div>
                `).join('') : '<span class="secondary" style="font-size: 0.84rem;">No open questions.</span>'}
              </div>

              <h3 class="card-title" style="margin-top: 24px; margin-bottom: 12px;">Recent Outcomes</h3>
              <p class="secondary" style="font-size: 0.84rem; line-height: 1.6;">
                ${live.status !== 'ready' ? blockText() : live.outcomes.length ? live.outcomes.slice(0, 6).map(o => {
                  const p = live.projects.get(o.project);
                  return `&bull; <a href="#/projects/${o.project}">${safe(p?.name || shortAddr(o.project))}</a>: ${o.kind}${o.detail ? ` (${safe(o.detail)})` : ''}`;
                }).join('<br>') : 'No outcomes yet on the test run 5 registry.'}
              </p>

              ${w && w.bondOwed > 0n ? `
                <h3 class="card-title" style="margin-top: 24px; margin-bottom: 12px;">Bonds Owed to You</h3>
                <p class="secondary" style="font-size: 0.84rem; margin-bottom: 10px;"><span class="mono">${fmtUnits(w.bondOwed, 18, 2)}</span> test IMD the token couldn't pay you at settlement.</p>
                <button class="btn btn-secondary btn-sm" id="btn-claim-bond">Claim to this wallet</button>
              ` : ''}
            </div>
          </div>
        </div>
      </div>
    `;

    const note = (text) => {
      f.note = text;
      const el = document.getElementById('step-apply-disabled');
      if (el) el.textContent = text || applyStatus();
    };

    let previewTimer = null;
    const preview = () => {
      clearTimeout(previewTimer);
      previewTimer = setTimeout(async () => {
        const ids = ['project', 'name', 'url', 'rate', 'beneficiary'];
        if (ids.some(id => validateApply(id, f[id]))) return;
        try {
          const ret = await ethCall(ADDRESSES.PROJECT_REGISTRY, encodeCall(SEL.applyQuestion, [
            ['address', f.project.trim()], ['string', f.name.trim()], ['string', f.url.trim()], ['uint', f.rate.trim()], ['address', f.beneficiary.trim()]
          ]));
          f.question = decString(ret, Number(decUint(words(ret)[0])));
          const q = document.querySelector('#apply-question code');
          if (q) q.textContent = f.question;
        } catch {}
      }, 300);
    };

    ['project', 'name', 'url', 'rate', 'beneficiary'].forEach((id) => {
      const el = document.getElementById(`apply-${id}`);
      const errEl = document.getElementById(`apply-${id}-error`);
      if (!el) return;
      if (f.errors[id]) el.setAttribute('aria-invalid', 'true');
      el.addEventListener('input', () => { f[id] = el.value; });
      el.addEventListener('blur', () => {
        f[id] = el.value;
        const err = validateApply(id, el.value);
        f.errors[id] = err;
        errEl.textContent = err;
        if (err) el.setAttribute('aria-invalid', 'true');
        else el.removeAttribute('aria-invalid');
        preview();
      });
    });
    preview();

    document.getElementById('btn-get-feetoken')?.addEventListener('click', async () => {
      try {
        await ensureSepolia();
        note('');
        await sendTx(ADDRESSES.ORACLE_FEE_TOKEN, encodeCall(SEL.mint, [['address', state.account], ['uint', 10n * 10n ** 18n]]), 'Get 10 test IMD');
      } catch (e) {
        note(walletError(e));
      }
    });

    document.getElementById('btn-approve-fee')?.addEventListener('click', async () => {
      try {
        note('');
        await sendTx(ADDRESSES.ORACLE_FEE_TOKEN, SEL.approve + encAddress(ADDRESSES.PROJECT_REGISTRY) + encUint(live.fee), 'Approve fee');
      } catch (e) {
        note(walletError(e));
      }
    });

    document.getElementById('btn-apply-listing')?.addEventListener('click', async () => {
      let hasErr = false;
      ['project', 'name', 'url', 'rate', 'beneficiary'].forEach((id) => {
        f[id] = document.getElementById(`apply-${id}`)?.value || '';
        f.errors[id] = validateApply(id, f[id]);
        if (f.errors[id]) hasErr = true;
      });
      if (hasErr) {
        renderApply();
        return;
      }
      try {
        note('Checking the project on Sepolia...');
        const project = f.project.trim();
        const code = await rpc('eth_getCode', [project, 'latest']);
        if (!code || code === '0x') throw new Error('That address has no contract code: only contracts can apply');
        const rec = decodeRecord(await ethCall(ADDRESSES.PROJECT_REGISTRY, encodeCall(SEL.projectOf, [['address', project]])));
        if (rec.listed) throw new Error('This project is already listed');
        if (rec.ask !== 0) throw new Error('This project already has an open question');
        await ensureSepolia();
        await loadWallet();
        // A project that reports an owner() can only be applied for by that owner or itself.
        let owner = null;
        try {
          owner = decAddress(words(await ethCall(ADDRESSES.PROJECT_REGISTRY, encodeCall(SEL.projectOwner, [['address', project]])))[0]).toLowerCase();
        } catch {}
        if (owner && owner !== '0x0000000000000000000000000000000000000000' && owner !== state.account && project.toLowerCase() !== state.account) {
          throw new Error(`Only this project's owner can apply for it: connect ${owner}`);
        }
        if (!live.wallet || live.wallet.feeToken < live.fee || live.wallet.feeAllowance < live.fee) throw new Error(applyStatus());
        note('');
        await sendTx(ADDRESSES.PROJECT_REGISTRY, encodeCall(SEL.applyListing, [
          ['address', project], ['string', f.name.trim()], ['string', f.url.trim()], ['uint', f.rate.trim()], ['address', f.beneficiary.trim()]
        ]), 'Apply for listing');
        note('Applied: the oracle panel usually answers within minutes.');
      } catch (e) {
        note(walletError(e));
      }
    });

    document.getElementById('btn-claim-bond')?.addEventListener('click', async () => {
      try {
        await sendTx(ADDRESSES.PROJECT_REGISTRY, encodeCall(SEL.claimBond, [['address', state.account]]), 'Claim bond');
      } catch (e) {
        showToast(walletError(e));
      }
    });
  }

  // --- Page: Leaderboard (#/leaderboard) ---
  function renderLeaderboard() {
    document.title = 'Leaderboard - imd/acc';
    // Trader and project points count the same credits: those inside a listing period.
    const points = new Map();
    const projectPoints = new Map(); // project -> { points, traders }
    for (const s of live.stacks) {
      if (!isListedAt(s.project, s.block)) continue;
      points.set(s.trader, (points.get(s.trader) || 0n) + s.imd);
      const key = s.project.toLowerCase();
      const e = projectPoints.get(key) || { points: 0n, traders: new Set() };
      e.points += s.imd;
      e.traders.add(s.trader);
      projectPoints.set(key, e);
    }
    const traders = [...points.entries()].sort((x, y) => (y[1] > x[1] ? 1 : y[1] < x[1] ? -1 : 0)).slice(0, 10);
    const projects = [...projectPoints.entries()]
      .map(([key, e]) => ({ p: live.projects.get(key), ...e }))
      .filter(x => x.p)
      .sort((x, y) => (y.points > x.points ? 1 : y.points < x.points ? -1 : 0))
      .slice(0, 10);
    const mine = state.account ? (points.get(state.account) || 0n) : null;
    const loading = live.status !== 'ready' ? `<tr><td colspan="3" class="secondary">${blockText()}</td></tr>` : '';

    appRoot.innerHTML = `
      <div class="page-view">
        <div class="page-header-block">
          <div class="page-tag">Cumulative Points &middot; ${blockText()}</div>
          <h1 class="page-title">Leaderboards</h1>
          <p class="page-desc">1 point per IMD stacked by a listed project, counted from the block it was listed. A project's points are the IMD its traders stacked while it was listed.</p>
        </div>

        <div class="grid-2">
          <div class="dashboard-card">
            <h3 class="card-title" style="margin-bottom: 16px;">Top Stackers</h3>
            <div class="projects-table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Rank</th>
                    <th>Trader</th>
                    <th>Points</th>
                  </tr>
                </thead>
                <tbody>
                  ${loading || (traders.length ? traders.map(([t, v], i) => `
                    <tr${t === state.account ? ' style="background: var(--bg-elevated);"' : ''}>
                      <td><strong>#${i + 1}</strong></td>
                      <td>${addrLink(t)}${t === state.account ? ' (You)' : ''}</td>
                      <td><strong class="mono" style="color: var(--accent-light);">${fmtUnits(v, 18, 2)}</strong></td>
                    </tr>`).join('') : '<tr><td colspan="3" class="secondary">No points yet: only credits from projects listed on the test run 5 registry earn points.</td></tr>')}
                  ${mine !== null && !loading && !points.has(state.account) ? `
                    <tr style="background: var(--bg-elevated);">
                      <td>-</td>
                      <td><span class="mono">${shortAddr(state.account)}</span> (You)</td>
                      <td><strong class="mono" style="color: var(--accent-light);">${fmtUnits(mine, 18, 2)}</strong></td>
                    </tr>` : ''}
                </tbody>
              </table>
            </div>
          </div>

          <div class="dashboard-card">
            <h3 class="card-title" style="margin-bottom: 16px;">Top Projects</h3>
            <div class="projects-table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Project</th>
                    <th>Points</th>
                    <th>Traders</th>
                  </tr>
                </thead>
                <tbody>
                  ${loading || (projects.length ? projects.map(({ p, points: v, traders: t }) => {
                    const st = projectState(p);
                    return `
                      <tr>
                        <td><a href="#/projects/${p.address}"><strong>${safe(p.name || shortAddr(p.address))}</strong></a> <span class="pill ${st.cls}">${st.label}</span></td>
                        <td class="mono" style="color: var(--accent-light);"><strong>${fmtUnits(v, 18, 2)}</strong></td>
                        <td class="mono">${t.size}</td>
                      </tr>`;
                  }).join('') : '<tr><td colspan="3" class="secondary">No project points yet: a project earns points for the IMD its traders stack while it is listed.</td></tr>')}
                </tbody>
              </table>
            </div>
          </div>
        </div>
      </div>
    `;
  }

  // --- Docs (#/docs and #/docs/<section>): GitBook-style sections ---
  const EXPLORER = {
    sepolia: 'https://sepolia.etherscan.io/address/',
    mainnet: 'https://etherscan.io/address/'
  };

  function docTable(headers, rows) {
    return `
      <div class="projects-table-wrap">
        <table class="data-table">
          <thead><tr>${headers.map(h => `<th>${h}</th>`).join('')}</tr></thead>
          <tbody>${rows.map(r => `<tr>${r.map(c => `<td>${c}</td>`).join('')}</tr>`).join('')}</tbody>
        </table>
      </div>`;
  }

  function docCode(title, code, id) {
    return `
      <div class="code-container">
        <div class="code-header">
          <span class="code-title">${title}</span>
          <button class="btn btn-secondary btn-sm copy-btn" data-clipboard-target="#${id}">Copy</button>
        </div>
        <pre class="code-block" id="${id}"><code>${safe(code)}</code></pre>
      </div>`;
  }

  function docAddr(addr) {
    return `<a class="mono" style="white-space: nowrap;" href="${EXPLORER.sepolia}${addr}" target="_blank" rel="noopener noreferrer" title="${addr}">${shortAddr(addr)} &nearr;</a>`;
  }

  function docContract(name, pill, pillClass, addr, desc, explorer) {
    return `
      <div class="contract-card">
        <div class="contract-card-header">
          <span class="contract-name">${name}</span>
          <span class="pill ${pillClass}">${pill}</span>
        </div>
        ${addr ? `
          <div class="address-row">
            <span class="address-text">${addr}</span>
            <button class="btn btn-secondary btn-sm copy-btn" data-clipboard="${addr}">Copy</button>
          </div>` : ''}
        <p class="secondary">${desc}${addr && explorer ? ` <a href="${explorer}${addr}" target="_blank" rel="noopener noreferrer">Explorer &nearr;</a>` : ''}</p>
      </div>`;
  }

  const INTEGRATION_SNIPPET = `// Once: let the Stacker pull IMD from your contract.
IERC20(imd).approve(address(stacker), type(uint256).max);

// On each trade, for the real trader: valid hookData, else the router's
// msgSender(), else sender only if it has no code. Never pay a router.
// Your rate: 25-100 bps, out of the fee you already charge.
uint256 cashback = imdSideAmount * RATE_BPS / 10_000;

// Check gas first, so no wallet estimate skips the cashback; 350k covers
// even the Stacker's first-ever credit, 60k more is for the fallback.
require(gasleft() >= 410_000, "imd/acc: insufficient gas");

try stacker.credit{gas: 350_000}(trader, cashback) {
    // the trader now holds the sIMD
} catch {
    // plain IMD instead: the trade never reverts
    IERC20(imd).transfer(trader, cashback);
}`;

  const STACKER_ABI = `function credit(address trader, uint256 imdAmount)
    external
    returns (uint256 shares);

function IMD() external view returns (address);
function SIMD() external view returns (address);
function projectStacked(address) external view returns (uint256);
function projectShares(address) external view returns (uint256);
function totalStacked() external view returns (uint256);

event Stacked(
    address indexed project,
    address indexed trader,
    uint256 imd,
    uint256 shares
);

error ZeroTrader();
error InvalidTrader(); // mainnet: the Stacker, the vault or the IMD token as trader
error AssetMismatch(address vaultAsset, address imd);
error ZeroShares();`;

  const DOCS = [
    {
      group: 'Getting started',
      pages: [
        {
          slug: 'introduction',
          title: 'Introduction',
          summary: 'imd/acc pays trading cashback as staked IMD (sIMD), straight into the trader\'s wallet.',
          keywords: 'overview what is sIMD cashback staked IMD btc/acc',
          body: `
            <p>Every trade in a participating project sends part of the trade, <strong>between 0.25% and 1%</strong> at the project's choice, back to the trader as <strong>sIMD</strong>: shares of IMD's staking vault, minted directly to the trader's wallet, where they keep earning the vault's yield. Nothing to claim, no new token, and no extra fee for the trader.</p>
            <div class="docs-features">
              <div class="docs-feature"><h4>No new token</h4><p>The cashback is IMD, staked. There is nothing else to buy.</p></div>
              <div class="docs-feature"><h4>No custody</h4><p>imd/acc never holds the cashback. The vault mints the shares directly to the trader.</p></div>
              <div class="docs-feature"><h4>No extra fee</h4><p>Projects pay out of fees they already charge, so traders pay nothing on top.</p></div>
              <div class="docs-feature"><h4>No owner</h4><p>The shared contracts have no admin, no fee, no pause and no upgrade.</p></div>
            </div>
            <h2 id="pieces">The pieces</h2>
            <ul>
              <li><strong>Stacker</strong>: one shared, ownerless contract every project calls with <code>credit(trader, amount)</code>. It pulls the IMD and deposits it into the sIMD vault for the trader.</li>
              <li><strong>ProjectRegistry</strong>: an ownerless list of the projects whose cashback earns <a href="#/docs/points">points</a>, decided by an IdentityMD oracle panel.</li>
              <li><strong>sIMD vault</strong>: IMD's own ERC-4626 staking vault. imd/acc only deposits into it.</li>
            </ul>
            <h2 id="status">Where it stands</h2>
            <p>The Stacker and the ProjectRegistry are live on Sepolia (latest: test run 5, launch #1428). The Stacker is live on Ethereum mainnet (launch #1409), against the real IMD and sIMD. See <a href="#/docs/contracts">Contracts</a> for every address and <a href="#/docs/roadmap">Roadmap</a> for what comes next.</p>
            <div class="docs-callout"><p>imd/acc is inspired by TokenWorks' btc/acc: the same idea of turning trading activity into a growing stack, here in staked IMD.</p></div>`
        },
        {
          slug: 'how-it-works',
          title: 'How it works',
          summary: 'One trade, one transaction: the cashback is staked for the trader inside the swap itself.',
          keywords: 'flow hook credit deposit vault shares stacked event',
          body: `
            <h2 id="flow">The flow</h2>
            ${docCode('Flow', `trader --trades--> project's pool and hook
                     |  takes 0.25%-1% of the trade in IMD,
                     |  out of the fee it already charges
                     v
          Stacker.credit(trader, amount)
                     |  pulls the IMD from the project
                     v
          sIMD.deposit(amount, trader)
                     |  shares minted to the trader
                     v
          Stacked(project, trader, imd, shares) --> points`, 'doc-flow')}
            <ol>
              <li>A trader trades in a participating pool, for example PLEA/IMD.</li>
              <li>The project's hook takes its cashback rate (0.25%&ndash;1%) of the trade on the IMD side, out of the fee it already charges, so IMD-paired pools need no extra swap.</li>
              <li>The hook calls <code>Stacker.credit(trader, amount)</code>. The Stacker pulls the IMD and calls <code>sIMD.deposit(amount, trader)</code>, so the vault mints the shares straight to the trader.</li>
              <li>The Stacker emits <code>Stacked(project, trader, imd, shares)</code>. That event is the record behind every figure and every point.</li>
            </ol>
            <h2 id="atomic">All in one transaction</h2>
            <p>The cashback is staked inside the trader's own swap. The Stacker keeps 0 IMD and 0 sIMD between calls; if the vault refuses the deposit, the credit reverts and moves nothing, and the project pays plain IMD instead (see <a href="#/docs/integration">Integration guide</a>).</p>
            <div class="docs-callout"><p><strong>One-block hold.</strong> The vault stamps any wallet that receives new shares, and that wallet can't redeem in the same block. Anyone can already deposit into the vault for someone else, so the Stacker adds nothing new here.</p></div>`
        },
        {
          slug: 'cashback-rate',
          title: 'Cashback rate',
          summary: 'Each project picks its rate between 0.25% and 1% of each trade, funded from its existing fees.',
          keywords: 'rate bps 25 100 basis points fee change',
          body: `
            <h2 id="range">0.25% to 1%, chosen by each project</h2>
            <p>Projects with thin fees can still join at 0.25%; others can offer up to 1% to attract traders. PLEA pays 0.5%. The rate is taken on the IMD side of each trade, <strong>out of the fee the project already charges</strong>: traders never pay extra.</p>
            ${docTable(['Rate', 'Basis points', 'Cashback on a 1,000 IMD trade'], [
              ['0.25%', '25', '2.5 IMD'],
              ['0.50%', '50', '5 IMD'],
              ['0.75%', '75', '7.5 IMD'],
              ['1.00%', '100', '10 IMD']
            ])}
            <h2 id="changes">Changing the rate</h2>
            <p>A listed project may change its rate later, as long as its code keeps every allowed rate between 0.25% and 1% and keeps the <a href="#/docs/fee-guard">fee guard</a> for every allowed setting. A change inside those limits keeps the listing.</p>
            <h2 id="per-credit">Checked per credit</h2>
            <p>Points count only credits within 25&ndash;100 bps of their own trade. A credit outside that range, or with no trade on the project's pool in that transaction, earns no points.</p>`
        },
        {
          slug: 'points',
          title: 'Points',
          summary: '1 point per IMD stacked, for traders of listed projects. Nothing is promised.',
          keywords: 'points leaderboard airdrop listed fromBlock dashboard',
          body: `
            <p>Every <code>Stacked</code> event is kept as a record. Points are the basis for the leaderboards and maybe a later airdrop; <strong>nothing is promised</strong>.</p>
            <h2 id="rules">How points work</h2>
            <ul>
              <li><strong>Trader points:</strong> 1 point per IMD stacked for the trader. A project with a higher rate gives its traders more cashback, so more points.</li>
              <li><strong>Project points:</strong> the IMD its traders stacked.</li>
              <li><strong>Listed projects only.</strong> Anyone can call <code>credit</code> with their own IMD; that's just staking for someone, so it earns no points. Only credits from a listed project count, from the block it was listed, never before.</li>
              <li><strong>Counted from events</strong>, which can't be changed or deleted. An indexer keeps the totals ready for the site; project totals are also on chain.</li>
            </ul>
            <h2 id="dashboard">What a trader sees</h2>
            ${docTable(['Figure', 'Where it comes from'], [
              ['Cashback received, points, split per project', 'their <code>Stacked</code> events'],
              ['sIMD held now', 'the vault, live'],
              ['What their cashback is worth today', 'the shares in their events, priced by the vault, live'],
              ['Earned on top (vault yield)', 'worth today minus cashback received']
            ])}
            <p>The all-traders dashboard and leaderboards (top traders, top projects, 7-day and 30-day views) come from the same events.</p>`
        }
      ]
    },
    {
      group: 'For traders',
      pages: [
        {
          slug: 'your-simd',
          title: 'Your sIMD',
          summary: 'What lands in your wallet, how it earns, and how to unstake.',
          keywords: 'trader sIMD vault yield redeem withdraw unstake erc-4626 decimals',
          body: `
            <h2 id="what">What you receive</h2>
            <p>Cashback arrives as <strong>sIMD</strong>, the share token of IMD's ERC-4626 staking vault on Ethereum (<code>0x9efa…7247</code>, 24 decimals). It is minted to your wallet in the same transaction as your trade. There is nothing to claim.</p>
            <h2 id="yield">How it earns</h2>
            <p>Each sIMD share is worth a growing amount of IMD as the vault earns, so your cashback keeps growing while you hold it. The vault's owner is renounced: nobody can pause it or sweep its funds.</p>
            <h2 id="unstake">Unstaking</h2>
            <p>You can redeem sIMD for IMD in the vault at any time, except in the block where new shares arrive (the vault's one-block hold).</p>
            <h2 id="points">Points</h2>
            <p>Trades in a <a href="#/docs/listing">listed</a> project also earn you 1 point per IMD of cashback. Check the <a href="#/leaderboard">Leaderboard</a> and <a href="#/stack">Your stack</a>.</p>
            <div class="docs-callout"><p><strong>On other chains</strong> (planned, Robinhood Chain first), your cashback waits on that chain and is delivered to Ethereum as sIMD. See <a href="#/docs/multichain">Multichain</a>.</p></div>`
        }
      ]
    },
    {
      group: 'For projects',
      pages: [
        {
          slug: 'integration',
          title: 'Integration guide',
          summary: 'Seven rules for paying cashback from your hook or pool without ever breaking a trade.',
          keywords: 'integrate hook uniswap v4 try catch fallback gasleft hookData tx.origin approve',
          body: `
            ${docCode('Solidity &middot; inside your hook', INTEGRATION_SNIPPET, 'doc-integration')}
            <h2 id="rules">The rules</h2>
            <div class="docs-grid">
              <div class="doc-rule-card"><span class="rule-number">1</span><div class="rule-content"><h4>Fund it from your fee</h4><p>Pick a rate from 0.25% to 1% and take it on the IMD side of the trade, out of the fee you already charge. The part of your fee that leaves you must be at least as large as the cashback (the <a href="#/docs/fee-guard">fee guard</a>).</p></div></div>
              <div class="doc-rule-card"><span class="rule-number">2</span><div class="rule-content"><h4>Never break a trade</h4><p>Wrap <code>credit</code> in <code>try/catch</code> and pay plain IMD to the trader if it fails.</p></div></div>
              <div class="doc-rule-card"><span class="rule-number">3</span><div class="rule-content"><h4>Pay the real trader</h4><p>Valid router <code>hookData</code> first; else the router's <code>msgSender()</code> during the swap; <code>sender</code> only if it has no code. Never <code>tx.origin</code>, never a router: in a Uniswap v4 hook <code>sender</code> is usually the router, and anyone can sweep what it holds. If no trader can be resolved, skip the cashback without blocking the trade.</p></div></div>
              <div class="doc-rule-card"><span class="rule-number">4</span><div class="rule-content"><h4>Check gas first</h4><p>Require <code>gasleft() &gt;= 410,000</code> before calling <code>credit{gas: 350,000}</code>, outside the <code>try/catch</code>. Otherwise a wallet's gas estimate picks the cheaper path without cashback.</p></div></div>
              <div class="doc-rule-card"><span class="rule-number">5</span><div class="rule-content"><h4>Budget the gas</h4><p>About 136k gas for a new trader and 102k for a repeat one on mainnet (whole transactions); the Stacker's first-ever credit about 232k, as it also approves the vault. A cap near the new-trader figure fails that first credit every time. See <a href="#/docs/gas">Gas &amp; costs</a>.</p></div></div>
              <div class="doc-rule-card"><span class="rule-number">6</span><div class="rule-content"><h4>Uniswap v4 hooks</h4><p>Include the <code>afterSwap</code> logic Uniswap's frontend whitelisting expects, resolve the router's <code>msgSender()</code> (rule 3, also with empty <code>hookData</code>), and warn users about copycat pools.</p></div></div>
              <div class="doc-rule-card"><span class="rule-number">7</span><div class="rule-content"><h4>Test the failure path</h4><p>On Sepolia, TestSIMD's owner can pause it; your hook should then pay plain IMD. See <a href="#/docs/testing">Testing on Sepolia</a>.</p></div></div>
            </div>
            <h2 id="approve">Approve once</h2>
            <p>The Stacker pulls IMD from <code>msg.sender</code>, so your contract approves it once. The Stacker's IMD and vault addresses are immutable, so the approval never needs to move.</p>
            <h2 id="after">After integrating</h2>
            <p>Verify your contract's source (Etherscan, Blockscout or Sourcify), then <a href="#/docs/listing">apply for listing</a> so your traders' cashback earns points.</p>`
        },
        {
          slug: 'fee-guard',
          title: 'Fee guard',
          summary: 'Why the part of your fee that really leaves must be at least as large as the cashback.',
          keywords: 'fee guard farming owner leaves burn locked liquidity prizes',
          body: `
            <p>A normal trader can't farm points: they pay the whole fee and get back only the cashback, which is smaller. A project owner also gets back their own share of the fee, so trading with themselves could be nearly free. The fee guard closes that.</p>
            <h2 id="parts">Split the fee into three parts</h2>
            ${docTable(['Part', 'Examples', 'Counts as "leaves"?'], [
              ['Cashback', 'the trader\'s sIMD', 'no'],
              ['Comes back to the owner', 'owner share, team treasury, liquidity the owner can withdraw', 'no'],
              ['Really leaves', 'burned tokens, liquidity locked forever, prizes paid to other people, fees to third parties', '<strong>yes</strong>']
            ])}
            <div class="docs-callout"><p><strong>Rule: "really leaves" &ge; cashback.</strong> Then every point an owner farms costs at least as much as it returns, plus price impact and gas. If the rate or the fee split can change, the code must keep this true for every allowed setting.</p></div>
            <h2 id="examples">Examples</h2>
            <ul>
              <li><strong>PLEA passes:</strong> fee 1.75% = 0.5% cashback + 0.5% owner + 0.25% locked liquidity + 0.25% burn + 0.25% season prizes. Leaves 0.75% &ge; 0.5%.</li>
              <li><strong>Fails:</strong> fee 1.25% = 1% cashback + 0.25% owner. Nothing leaves, so points are almost free. Such a project can still use imd/acc, unlisted.</li>
            </ul>`
        },
        {
          slug: 'listing',
          title: 'Listing & the registry',
          summary: 'How a project gets listed, challenged or delisted by an IdentityMD oracle panel, with no owner.',
          keywords: 'apply listing registry oracle panel challenge bond cooldown beneficiary handoff claimBond owed expire rules',
          body: `
            <p>Any project can use imd/acc: its traders get real sIMD from the first credit. <strong>Listing</strong> decides which projects' credits also earn points. The <strong>ProjectRegistry</strong> has no owner: an IdentityMD oracle panel answers each question.</p>
            <h2 id="steps">Steps</h2>
            <ol>
              <li><strong>Integrate</strong> following the <a href="#/docs/integration">integration guide</a>, and verify your source.</li>
              <li><strong>Apply.</strong> Anyone calls <code>applyListing(project, name, sourceUrl, rateBps, beneficiary)</code> (or uses the <a href="#/apply">Apply</a> page) and pays the oracle fee, read live from the Intake: 0.5 IMD today.</li>
              <li><strong>The panel answers</strong> within minutes. 15 seats, 11 must agree. <strong>Yes</strong> lists the project from that block; <strong>no</strong> rejects it, and it can apply again.</li>
              <li><strong>No answer</strong> (a split panel or a refused question) clears the application; it can be sent again at once. Nothing is listed.</li>
            </ol>
            <h2 id="rules">What the panel checks</h2>
            ${docTable(['Rule', 'In short'], [
              ['trading', 'Every credit happens inside a trade, for that trade\'s trader, with IMD from that trade\'s fees.'],
              ['trader', 'The project never picks who is credited; the hookData address (else the sender) counts as the trader.'],
              ['otherPayouts', 'Cashback paid outside the Stacker (for example the plain-IMD fallback) is allowed and simply earns no points.'],
              ['rate', 'Each credit is the stated rate of its trade, between 25 and 100 bps.'],
              ['feeGuard', 'The parts of the fee that leave for good add up to at least the cashback, for every allowed setting.'],
              ['lockedValue', 'Value no owner or team wallet can ever withdraw counts as leaving for good.'],
              ['beneficiary', 'The beneficiary is the project\'s owner, or a wallet its source or website names as team or treasury.'],
              ['evidence', 'Judged from verified source on Etherscan, Blockscout or Sourcify, and on-chain reads.']
            ])}
            <h2 id="challenges">Challenges</h2>
            <p>Anyone can challenge a listed project after its cooldown with <code>challengeForBeneficiary(project, reason, beneficiary)</code>, paying the oracle fee plus a bond. If the panel says it still meets the rules, it stays listed and <strong>the bond goes to its beneficiary</strong> (the cooldown doesn't restart); if not, it is delisted from that block, earlier points stay, and the challenger gets the bond back.</p>
            <h2 id="beneficiary">Beneficiary and bonds</h2>
            <ul>
              <li>The <strong>beneficiary</strong> holds the project's points, since a hook contract can't receive an airdrop. It can hand them to another wallet with <code>setBeneficiary</code>, at most once per day and never while a question is open.</li>
              <li>If the token ever refuses to pay a bond, the question still settles and the bond is recorded as owed; its owner takes it with <code>claimBond(to)</code>, to any wallet.</li>
              <li><code>expire(project)</code> lets anyone clear a question that can no longer be answered, after a day or once the Intake completed it.</li>
            </ul>
            <h2 id="settings">Settings</h2>
            ${docTable(['Setting', 'Sepolia', 'Ethereum (planned)'], [
              ['Oracle fee', '0.5 test IMD', '0.5 IMD'],
              ['Challenge bond', '5 test IMD', '20 IMD'],
              ['Challenge cooldown', '1 hour', '7 days'],
              ['Panel', '15 seats, 11 agree', '15 seats, 11 agree'],
              ['Open question expires', '1 day', '1 day'],
              ['Beneficiary handoff', 'once per day', 'once per day']
            ])}`
        },
        {
          slug: 'testing',
          title: 'Testing on Sepolia',
          summary: 'Test IMD from a faucet, a pausable test vault, and the live Stacker and registry.',
          keywords: 'sepolia testnet faucet testimd testsimd pause fallback mint self stack',
          body: `
            <h2 id="tokens">Get test tokens</h2>
            <ul>
              <li><strong>TestIMD</strong> (<code>0x2b69…1e82</code>): call <code>faucet()</code> for 10,000 tIMD per address every 24 hours, or use <a href="#/stack">Your stack</a>.</li>
              <li><strong>Oracle test IMD</strong> (<code>0x44a1…f89a</code>): pays the registry's oracle fee; anyone can <code>mint(to, amount)</code>.</li>
            </ul>
            <h2 id="credit">Try a credit</h2>
            <p>Approve the Stacker for TestIMD, then call <code>credit(yourAddress, amount)</code>. The TestSIMD vault mints you shares. Credits from your own wallet are direct, so they earn no points.</p>
            <h2 id="fallback">Test your fallback</h2>
            <p>TestSIMD is a copy of StakedIMD whose owner can pause it, so integrators can check that their hook pays plain IMD when <code>credit</code> reverts. The mainnet vault can't be paused (its owner is renounced).</p>
            <h2 id="gas">Sepolia gas</h2>
            <p>Sepolia charges much more for new storage than mainnet: a first credit for a new trader has used 0.7M&ndash;1.2M gas there. Always use estimates &times; 1.3.</p>`
        }
      ]
    },
    {
      group: 'Reference',
      pages: [
        {
          slug: 'contracts',
          title: 'Contracts',
          summary: 'Every imd/acc deployment and the IMD contracts it works with.',
          keywords: 'addresses deployments stacker registry testimd testsimd mainnet sepolia explorer copy',
          body: `
            <h2 id="sepolia">Sepolia (chain 11155111)</h2>
            <div class="contracts-grid">
              ${docContract('Stacker', 'Live', 'pill-live', ADDRESSES.STACKER, 'The cashback funnel every project calls (launch #1294). The mainnet Stacker adds one check: it refuses the Stacker, the vault and the IMD token as the trader.', EXPLORER.sepolia)}
              ${docContract('ProjectRegistry', 'Live', 'pill-live', ADDRESSES.PROJECT_REGISTRY, 'The current registry (test run 5, launch #1428): rules v3, owner-only applications, one handoff per day, owed bonds.', EXPLORER.sepolia)}
              ${docContract('TestIMD', 'Sepolia', 'pill-live', ADDRESSES.TEST_IMD, 'Test IMD with a faucet: 10,000 tIMD per address every 24 hours.', EXPLORER.sepolia)}
              ${docContract('TestSIMD vault', 'Sepolia', 'pill-live', ADDRESSES.TEST_SIMD, 'A copy of StakedIMD whose owner can pause it, to test fallbacks.', EXPLORER.sepolia)}
              ${docContract('Oracle test IMD', 'Sepolia', 'pill-live', ADDRESSES.ORACLE_FEE_TOKEN, 'Pays the registry\'s oracle fee and bonds; anyone can mint it.', EXPLORER.sepolia)}
              ${docContract('Intake v2', 'IdentityMD', 'pill-test', ADDRESSES.INTAKE_V2, 'IdentityMD\'s oracle intake: the same address on Ethereum, Sepolia and Robinhood Chain.', EXPLORER.sepolia)}
            </div>
            <h2 id="mainnet">Ethereum mainnet</h2>
            <div class="contracts-grid">
              ${docContract('IMD', 'Mainnet', 'pill-live', ADDRESSES.MAINNET_IMD, 'Standard 18-decimal ERC-20 (a LayerZero OFT), no transfer fee.', EXPLORER.mainnet)}
              ${docContract('sIMD vault', 'Mainnet', 'pill-live', ADDRESSES.MAINNET_SIMD, 'ERC-4626 staking vault. Owner renounced: nobody can pause it or sweep its funds.', EXPLORER.mainnet)}
              ${docContract('Stacker', 'Live', 'pill-live', ADDRESSES.MAINNET_STACKER, 'Launch #1409, block 26,176,629: the cashback funnel against the real IMD and sIMD, audited by the IMD swarm. Source verified on Sourcify.', EXPLORER.mainnet)}
              ${docContract('ProjectRegistry', 'Planned', 'pill-planned', '', 'A later launch: the Sepolia registry\'s code, with a 20 IMD bond and a 7-day cooldown.', '')}
            </div>
            <h2 id="earlier">Earlier Sepolia deployments</h2>
            ${docTable(['Contract', 'Address', 'Note'], [
              ['ProjectRegistry, test run 4 (#1378)', docAddr(ADDRESSES.REGISTRY_RUN4), 'Rules v2; PLEA listed and defended in the live trial.'],
              ['ProjectRegistry, test run 3 (#1371)', docAddr(ADDRESSES.REGISTRY_RUN3), 'Rules v2, before owed bonds.'],
              ['ProjectRegistry, test run 2 (#1294)', docAddr(ADDRESSES.REGISTRY_RUN2), 'Rules v1.'],
              ['Stacker, first run (#1129)', docAddr(ADDRESSES.STACKER_V1), 'Also stored per-trader totals on chain.']
            ])}`
        },
        {
          slug: 'stacker-api',
          title: 'Stacker API',
          summary: 'The one function projects call, the event behind every figure, and the views.',
          keywords: 'abi credit stacked event projectStacked totalStacked errors zerotrader assetmismatch zeroshares',
          body: `
            ${docCode('Solidity &middot; Stacker interface', STACKER_ABI, 'doc-stacker-abi')}
            <h2 id="credit">credit(trader, imdAmount)</h2>
            <p>Pulls <code>imdAmount</code> IMD from <code>msg.sender</code> (the project) and calls <code>sIMD.deposit(imdAmount, trader)</code>. Returns the shares minted to the trader.</p>
            ${docTable(['Case', 'Result'], [
              ['<code>trader</code> is zero', 'reverts <code>ZeroTrader</code>'],
              ['<code>trader</code> is the Stacker, the vault or the IMD token', 'reverts <code>InvalidTrader</code> on mainnet: shares there could never move (the Sepolia Stacker predates this check)'],
              ['<code>imdAmount</code> is zero', 'returns 0: no transfer, no event, no state change'],
              ['first non-zero credit ever', 'checks <code>sIMD.asset() == IMD</code> (<code>AssetMismatch</code> otherwise) and approves the vault once; a failed credit rolls both back'],
              ['the vault mints 0 shares', 'reverts <code>ZeroShares</code>'],
              ['vault paused, allowance or balance short', 'reverts with the vault\'s or token\'s own error and moves nothing']
            ])}
            <h2 id="views">Views</h2>
            <ul>
              <li><code>projectStacked(project)</code>, <code>projectShares(project)</code>: IMD stacked and shares minted through each project.</li>
              <li><code>totalStacked()</code>: IMD stacked through the Stacker in total.</li>
              <li>Per-trader figures come from the <code>Stacked</code> events, so a credit writes no new storage per trader.</li>
            </ul>
            <h2 id="properties">Properties</h2>
            <p>No owner, admin, fee, pause or upgrade. Immutable IMD and sIMD. <code>nonReentrant</code>, OpenZeppelin <code>SafeERC20</code>. Holds 0 IMD and 0 sIMD between calls (tested as an invariant).</p>`
        },
        {
          slug: 'registry-api',
          title: 'Registry API',
          summary: 'Every function, view and event of the ProjectRegistry.',
          keywords: 'abi applyListing challengeForBeneficiary challenge expire setBeneficiary claimBond projectOf isListed bondOwed events',
          body: `
            <h2 id="write">Functions</h2>
            ${docTable(['Function', 'Who', 'What it does'], [
              ['<code>applyListing(project, name, sourceUrl, rateBps, beneficiary)</code>', 'anyone', 'Pays the oracle fee and asks the panel. The project must be a contract; rate 25&ndash;100; name 1&ndash;48 and URL 12&ndash;200 printable ASCII characters, without quotes, backslashes or square brackets. One open question per project.'],
              ['<code>challengeForBeneficiary(project, reason, beneficiary)</code>', 'anyone', 'For a listed project after its cooldown; pays the fee plus the bond. Reverts if the beneficiary changed from the one named. Reason 1&ndash;280 characters.'],
              ['<code>challenge(project, reason)</code>', 'anyone', 'The same, only until the project\'s first beneficiary handoff.'],
              ['<code>expire(project)</code>', 'anyone', 'Clears a question after a day, or once the Intake completed it without a settled answer. Returns a challenger\'s bond.'],
              ['<code>setBeneficiary(project, wallet)</code>', 'the beneficiary', 'Hands the project\'s points to another wallet: at most once per day, never while a question is open.'],
              ['<code>claimBond(to)</code>', 'whoever is owed', 'Sends the bonds the token refused to pay you at settlement to <code>to</code>.']
            ])}
            <h2 id="views">Views</h2>
            ${docTable(['View', 'Returns'], [
              ['<code>ORACLE_FEE()</code>', 'the oracle fee, read live from the Intake'],
              ['<code>projectOf(project)</code>', 'the record: listed, rate, listing blocks, beneficiary, cooldown and any open question'],
              ['<code>isListed(project)</code>', 'whether the project is listed now'],
              ['<code>bondOwed(wallet)</code>', 'bonds waiting for <code>claimBond</code>'],
              ['<code>handoffOpenAt(project)</code>', 'when the next beneficiary handoff is allowed'],
              ['<code>definitions(project, rateBps, beneficiary)</code>', 'the panel\'s rules, as sent with each question'],
              ['<code>challengeBond()</code>, <code>challengeCooldown()</code>', 'the deployment\'s bond and cooldown'],
              ['<code>PANEL_SIZE</code>, <code>QUORUM</code>, <code>PENDING_EXPIRY</code>, <code>HANDOFF_INTERVAL</code>', '15, 11, 1 day, 1 day']
            ])}
            <h2 id="events">Events</h2>
            <p><code>Applied</code>, <code>Listed</code>, <code>Rejected</code>, <code>Challenged</code>, <code>Defended</code>, <code>Delisted</code>, <code>AskCleared</code>, <code>BeneficiarySet</code>, <code>BondOwed</code>, <code>BondClaimed</code>. Points are counted inside the periods between <code>Listed</code> and <code>Delisted</code>.</p>
            <h2 id="callbacks">Oracle callbacks</h2>
            <p><code>onOracleResult</code> (selector <code>0x510379c7</code>) and <code>onOracleFailure</code> (<code>0xa7980e31</code>) accept calls only from the Intake. An answer counts only for the registry's own open request, signed by the oracle signer for this contract after the question was asked, from a full panel that agreed.</p>`
        },
        {
          slug: 'data-api',
          title: 'Data API',
          summary: 'Read-only JSON files with every chain\'s cashback and points, for apps, wallets, bots and agents.',
          keywords: 'api data json snapshot points leaderboard export index fetch cors version',
          body: `
            <p>Every chain's cashback and points, rebuilt from the chain about every 15 minutes and published with this site. No key and no server: any site or script can fetch them.</p>
            ${docTable(['File', 'What it holds'], [
              ['<a href="./data/v1/index.json"><code>/data/v1/index.json</code></a>', 'The chains that have a file, with each file\'s last block. Start here.'],
              ['<a href="./data/v1/sepolia.json"><code>/data/v1/sepolia.json</code></a>', 'Sepolia: the test run 2 Stacker and the test run 5 registry.'],
              ['<a href="./data/v1/ethereum.json"><code>/data/v1/ethereum.json</code></a>', 'Ethereum mainnet: the Stacker (launch #1409). No registry yet, so no points.']
            ])}
            <h2 id="rules">What the numbers mean</h2>
            <ul>
              <li><strong>From events only</strong>, recomputed from scratch each time: the Stacker's <code>Stacked</code> events and the registry's listing events, up to a block 12 behind the chain's head.</li>
              <li><strong>Points:</strong> 1 per IMD stacked by a project inside one of its listing periods. A project's points are the IMD its traders stacked while it was listed.</li>
              <li><strong>Checked</strong> against the Stacker's own totals at the same block before publishing; if a build fails, the previous file stays.</li>
              <li><strong>Amounts are strings</strong> of whole numbers in the smallest unit (18 decimals for IMD and points, 24 for sIMD shares), so nothing loses precision.</li>
            </ul>
            <h2 id="fields">Main fields</h2>
            ${docTable(['Field', 'Meaning'], [
              ['<code>blocks.to</code>, <code>blocks.toTime</code>', 'The last block counted. Files are usually 15-30 minutes behind the chain.'],
              ['<code>totals</code>', 'IMD, shares and points in all; credits, traders, projects, listed projects.'],
              ['<code>projects[]</code>', 'Address, name, status (<code>listed</code>, <code>applied</code>, <code>challenged</code>, <code>rejected</code>, <code>delisted</code>, <code>cleared</code>, <code>direct</code>), rate, beneficiary, listing periods, IMD, points, traders.'],
              ['<code>traders[]</code>', 'Address, IMD, shares, points and credits, split per project.']
            ])}
            ${docCode('Read a wallet\'s points', `const index = await (await fetch("https://imdacc.fun/data/v1/index.json")).json();
const snap = await (await fetch("https://imdacc.fun/data/v1/" + index.chains[0].file)).json();
const me = snap.traders.find((t) => t.address === wallet.toLowerCase());
const points = me ? Number(BigInt(me.points) / 10n ** 14n) / 1e4 : 0;`, 'code-data-api')}
            <p><strong>Stable:</strong> version 1 keeps its fields and URLs; new fields may be added. A breaking change comes as <code>/data/v2/</code>, next to v1 for a while. The full format is in <a href="https://github.com/khaed1/imd-acc/blob/main/docs/data-api.md" target="_blank" rel="noopener noreferrer">docs/data-api.md</a>.</p>`
        },
        {
          slug: 'gas',
          title: 'Gas & costs',
          summary: 'Measured costs of crediting, and who pays them.',
          keywords: 'gas cost estimate mainnet sepolia fork 1.3',
          body: `
            <h2 id="credit">Crediting</h2>
            ${docTable(['Call (whole transaction)', 'Ethereum mainnet (fork test)'], [
              ['First credit ever (also checks and approves the vault)', '231,847 gas'],
              ['Credit to a new trader', '135,735 gas'],
              ['Repeat credit', '101,535 gas'],
              ['Deploying the Stacker', '584,421 gas']
            ])}
            <p>Inside a swap, the trader pays about 0.11M extra gas for a new trader and 0.075M for a repeat one, beyond the swap's own cost. Wallets should send estimates &times; 1.3.</p>
            <h2 id="who">Who pays</h2>
            <ul>
              <li><strong>On Ethereum:</strong> the trader, inside their own swap. The project pays no extra gas, and imd/acc has no treasury or relayer.</li>
              <li><strong>On other chains</strong> (planned): the trader's swap pays the small local credit; delivery to Ethereum is paid by a small tip (see <a href="#/docs/multichain">Multichain</a>).</li>
            </ul>`
        },
        {
          slug: 'security',
          title: 'Security & trust',
          summary: 'What the contracts can and can\'t do, how they were audited, and what you trust.',
          keywords: 'security audit trust ownerless immutable oracle signer limits',
          body: `
            <h2 id="design">Design</h2>
            <ul>
              <li><strong>No owner anywhere</strong>: no admin, fee, pause or upgrade in the Stacker or the registry.</li>
              <li><strong>Immutable wiring</strong>: the Stacker's IMD and vault, and the registry's Intake, fee token, Stacker, signer, bond and cooldown are fixed at deployment.</li>
              <li><strong>Holds nothing it shouldn't</strong>: the Stacker holds nothing between calls; the registry holds only open challenge bonds and bonds owed.</li>
              <li><code>nonReentrant</code> on every state-changing entry point, OpenZeppelin <code>SafeERC20</code>, constructors that make no external call.</li>
            </ul>
            <h2 id="audits">Audits</h2>
            <p>Every launch was built and audited by the <a href="https://imd.fun" target="_blank" rel="noopener noreferrer">IMD swarm</a>: an import audit, four specialist audits (math, permissions, economics, control flow), a judge that reproduces and ranks findings, an independent review, and reproducible bytecode. Sepolia launches #1129, #1294, #1371, #1378 and #1428, and the mainnet launch #1409; each finding was fixed or documented. The tests (unit, fuzz, invariants, and forks of mainnet and Sepolia) are in the repository.</p>
            <h2 id="trust">What you trust</h2>
            <ul>
              <li><strong>The sIMD vault</strong>, IMD's own ERC-4626 vault, whose owner is renounced.</li>
              <li><strong>For listings:</strong> the oracle panel's answers, the oracle signer's key, and the Intake, which pairs each answer with its question.</li>
              <li><strong>For multichain</strong> (planned): IMD's own LayerZero bridge.</li>
            </ul>
            <h2 id="limits">Known limits</h2>
            <ul>
              <li>One open question per project, first come: a project can take its own slot with a self-challenge, at the cost of the fee each time. Each one still puts the project before the panel.</li>
              <li>The oracle signer and Intake can't be changed; a new registry would replace this one. The Stacker never reads the registry, so that needs no Stacker change.</li>
            </ul>`
        }
      ]
    },
    {
      group: 'More',
      pages: [
        {
          slug: 'multichain',
          title: 'Multichain',
          summary: 'Cashback from projects on other chains, delivered to Ethereum as sIMD.',
          keywords: 'multichain robinhood base arbitrum layerzero remotestacker stackreceiver tip bridge',
          body: `
            <div class="docs-callout docs-callout-warn"><p><strong>Designed, not built yet.</strong> Robinhood Chain comes first (PondPad), then Base and Arbitrum.</p></div>
            <h2 id="how">How it works</h2>
            <p>The sIMD vault exists only on Ethereum. On other chains, cashback waits per trader and is delivered to Ethereum as sIMD through <strong>IMD's own LayerZero bridge</strong>.</p>
            ${docTable(['Contract', 'Where', 'What it does'], [
              ['<code>RemoteStacker</code>', 'each other chain', 'The same <code>credit(trader, imdAmount)</code>, so integrating is identical. Adds the IMD to the trader\'s waiting balance and emits <code>Queued(project, trader, imd)</code>: the points record.'],
              ['<code>StackReceiver</code>', 'Ethereum', 'Receives the IMD with the list of traders and amounts, and deposits into sIMD for each.']
            ])}
            <p>Anyone can <code>flush</code> up to 50 traders' waiting cashback and earn a tip: 2% &times; (hours waiting &divide; 12) of each trader's cashback, at most 2%. The trader always gets at least 98%. Points are counted on the chain where the trade happened, when it happened.</p>
            <h2 id="listing">Listing on other chains</h2>
            <p>One registry per chain, with the same code and the same Apply page. On Robinhood Chain the oracle fee and bonds are paid in Robinhood Chain's IMD (<code>0x5f7b…7127</code>), the same token over IMD's bridge.</p>`
        },
        {
          slug: 'roadmap',
          title: 'Roadmap',
          summary: 'What is done and what comes next.',
          keywords: 'roadmap next mainnet indexer dashboard registry multichain eth route',
          body: `
            <ol>
              <li><strong>Sepolia test runs</strong> (done): the Stacker and the ProjectRegistry, now at test run 5 (launch #1428).</li>
              <li><strong>Live listing trial</strong> on Sepolia (done, 2026-10-12): PLEA listed by the oracle panel, a negative case rejected, and a challenge against PLEA defended.</li>
              <li><strong>The Stacker on Ethereum mainnet</strong> (done, 2026-10-12, launch #1409), with a full IMD swarm audit. PLEA mainnet uses its address.</li>
              <li><strong>Indexer and mainnet dashboard</strong>: each trader's cashback, points and value, and the leaderboards.</li>
              <li><strong>ProjectRegistry on mainnet</strong>: a 20 IMD challenge bond and a 7-day cooldown.</li>
              <li><strong>Multichain</strong>: Robinhood Chain first, then Base and Arbitrum.</li>
              <li><strong>v2, the ETH route</strong>, for projects whose fees are in ETH: pending ETH is swapped to IMD in guarded batches, then staked. Built once such a project wants in.</li>
            </ol>`
        },
        {
          slug: 'faq',
          title: 'FAQ',
          summary: 'Short answers to common questions.',
          keywords: 'faq questions claim token airdrop cut fee unstake',
          body: `
            <h3>Do I need to claim my cashback?</h3>
            <p>No. The sIMD is minted to your wallet inside your trade.</p>
            <h3>Is there an imd/acc token?</h3>
            <p>No. The cashback is IMD, staked. Points may be the basis for something later, but nothing is promised.</p>
            <h3>Does imd/acc take a cut?</h3>
            <p>No. The Stacker takes no fee and has no owner; the project pays the cashback out of fees it already charges.</p>
            <h3>Can I unstake?</h3>
            <p>Yes, any time in the sIMD vault, except in the block where new shares arrive.</p>
            <h3>What if the vault refuses a deposit?</h3>
            <p>The credit reverts and moves nothing, and an integrated project pays you plain IMD instead. Your trade still goes through.</p>
            <h3>Can anyone call credit?</h3>
            <p>Yes, but that's just staking for someone. Only credits from listed projects earn points.</p>
            <h3>Who decides which projects are listed?</h3>
            <p>An IdentityMD oracle panel, through the ownerless ProjectRegistry. Anyone can apply or challenge.</p>`
        },
        {
          slug: 'resources',
          title: 'Resources',
          summary: 'Source code, specs and related projects.',
          keywords: 'github llms.txt design history imd btc/acc links',
          body: `
            <ul>
              <li><a href="https://github.com/khaed1/imd-acc" target="_blank" rel="noopener noreferrer">GitHub repository</a>: contracts, tests, design notes and history.</li>
              <li><a href="https://github.com/khaed1/imd-acc/blob/main/docs/design.md" target="_blank" rel="noopener noreferrer">Design notes</a>: every decision, with the reasons.</li>
              <li><a href="https://github.com/khaed1/imd-acc/blob/main/docs/listing.md" target="_blank" rel="noopener noreferrer">Listing guide</a>: the checklist and the fee guard in full.</li>
              <li><a href="./llms.txt" target="_blank">llms.txt</a>: the spec for agents.</li>
              <li><a href="https://imd.fun" target="_blank" rel="noopener noreferrer">IMD</a> and <a href="https://imd.fun/docs/" target="_blank" rel="noopener noreferrer">IMD docs</a>.</li>
              <li><a href="https://github.com/token-works/archive" target="_blank" rel="noopener noreferrer">btc/acc by TokenWorks</a>, the inspiration.</li>
            </ul>`
        }
      ]
    }
  ];

  const DOC_PAGES = DOCS.flatMap(g => g.pages.map(p => ({ ...p, group: g.group })));

  function docText(html) {
    const d = document.createElement('div');
    d.innerHTML = html;
    return (d.textContent || '').toLowerCase();
  }

  function renderDocs(slug) {
    const index = DOC_PAGES.findIndex(p => p.slug === slug);
    if (index < 0) {
      location.replace('#/docs');
      return;
    }
    const page = DOC_PAGES[index];
    const prev = DOC_PAGES[index - 1];
    const next = DOC_PAGES[index + 1];
    document.title = `${page.title} - imd/acc Docs`;

    appRoot.innerHTML = `
      <div class="page-view">
        <div class="docs-layout">
          <button class="btn btn-secondary docs-mobile-toggle" id="docs-toggle" aria-expanded="false" aria-controls="docs-sidebar">
            <span>Sections &middot; ${safe(page.title)}</span>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polyline points="6 9 12 15 18 9"></polyline></svg>
          </button>

          <aside class="docs-sidebar" id="docs-sidebar">
            <div class="docs-search">
              <input type="search" id="docs-search" class="form-input" placeholder="Search docs..." aria-label="Search docs">
            </div>
            <nav aria-label="Documentation">
              ${DOCS.map(g => `
                <div class="docs-nav-group">
                  <div class="docs-nav-heading">${g.group}</div>
                  <ul class="docs-nav-list">
                    ${g.pages.map(p => `
                      <li data-doc="${p.slug}"><a href="#/docs/${p.slug}" class="docs-nav-link${p.slug === page.slug ? ' active' : ''}"${p.slug === page.slug ? ' aria-current="page"' : ''}>${p.title}</a></li>
                    `).join('')}
                  </ul>
                </div>
              `).join('')}
              <p class="docs-search-empty" id="docs-search-empty" hidden>No matching sections.</p>
            </nav>
          </aside>

          <article class="docs-article">
            <div class="page-header-block">
              <div class="page-tag">Docs &middot; ${page.group}</div>
              <h1 class="page-title">${page.title}</h1>
              <p class="page-desc">${page.summary}</p>
            </div>
            <div class="docs-body" id="docs-body">${page.body}</div>

            <nav class="docs-pager" aria-label="Previous and next sections">
              ${prev ? `<a href="#/docs/${prev.slug}" class="docs-pager-link prev"><span class="docs-pager-label">&larr; Previous</span><span class="docs-pager-title">${prev.title}</span></a>` : ''}
              ${next ? `<a href="#/docs/${next.slug}" class="docs-pager-link next"><span class="docs-pager-label">Next &rarr;</span><span class="docs-pager-title">${next.title}</span></a>` : ''}
            </nav>
            <div class="docs-meta">
              <span>imd/acc documentation</span>
              <a href="https://github.com/khaed1/imd-acc" target="_blank" rel="noopener noreferrer">Source on GitHub &nearr;</a>
            </div>
          </article>

          <aside class="docs-toc" id="docs-toc" aria-label="On this page"></aside>
        </div>
      </div>
    `;

    // "On this page": the section's headings, scrolled to without touching the hash route.
    const headings = [...document.querySelectorAll('#docs-body h2[id]')];
    const toc = document.getElementById('docs-toc');
    if (toc && headings.length) {
      toc.innerHTML = `
        <div class="docs-toc-title">On this page</div>
        ${headings.map(h => `<button class="docs-toc-link" data-scroll="${h.id}">${safe(h.textContent)}</button>`).join('')}
      `;
      toc.querySelectorAll('[data-scroll]').forEach(btn => {
        btn.addEventListener('click', () => {
          document.getElementById(btn.getAttribute('data-scroll'))?.scrollIntoView({ behavior: 'smooth', block: 'start' });
        });
      });
    }

    // Small screens: the sections list folds behind a toggle.
    const toggle = document.getElementById('docs-toggle');
    const sidebar = document.getElementById('docs-sidebar');
    toggle?.addEventListener('click', () => {
      const open = sidebar.classList.toggle('open');
      toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    });

    // Search: filters the sections by title, keywords and text; Enter opens the first match.
    const search = document.getElementById('docs-search');
    const empty = document.getElementById('docs-search-empty');
    search?.addEventListener('input', () => {
      const q = search.value.trim().toLowerCase();
      let shown = 0;
      document.querySelectorAll('.docs-nav-group').forEach(groupEl => {
        let groupShown = 0;
        groupEl.querySelectorAll('li[data-doc]').forEach(li => {
          const p = DOC_PAGES.find(x => x.slug === li.getAttribute('data-doc'));
          if (!p._text) p._text = `${p.title} ${p.keywords} ${p.summary} ${docText(p.body)}`.toLowerCase();
          const match = !q || p._text.includes(q);
          li.hidden = !match;
          if (match) groupShown++;
        });
        groupEl.hidden = groupShown === 0;
        shown += groupShown;
      });
      if (empty) empty.hidden = shown > 0;
    });
    search?.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return;
      const q = search.value.trim().toLowerCase();
      const visible = [...document.querySelectorAll('.docs-nav-list li:not([hidden]) a')];
      const best = visible.find(a => a.textContent.toLowerCase().includes(q)) || visible[0];
      if (best) location.hash = best.getAttribute('href');
    });
  }

  // --- Page: 404 Not Found ---
  function renderNotFound() {
    document.title = 'Page Not Found - imd/acc';

    appRoot.innerHTML = `
      <div class="page-view" style="text-align: center; padding: 60px 0;">
        <h1 class="page-title">Page Not Found</h1>
        <p class="secondary" style="margin-bottom: 24px;">The route you navigated to does not exist.</p>
        <a href="#/" class="btn btn-primary">&larr; Return to Overview</a>
      </div>
    `;
  }

  // --- Common Listeners ---
  function initCommonListeners() {
    document.querySelectorAll('.copy-btn').forEach(btn => {
      btn.onclick = () => {
        const text = btn.getAttribute('data-clipboard') ||
          (btn.getAttribute('data-clipboard-target') &&
           document.querySelector(btn.getAttribute('data-clipboard-target'))?.innerText);
        if (text) {
          navigator.clipboard.writeText(text.trim()).then(() => showToast('Copied to clipboard!'));
        }
      };
    });
  }

  // --- Global Init ---
  function init() {
    applyTheme(state.theme);

    // Theme Toggle
    document.getElementById('theme-toggle')?.addEventListener('click', () => {
      applyTheme(state.theme === 'dark' ? 'light' : 'dark');
    });

    // Mobile Menu Toggle
    const mobileBtn = document.getElementById('mobile-toggle');
    const navMenu = document.getElementById('nav-menu');
    mobileBtn?.addEventListener('click', (e) => {
      e.stopPropagation();
      const isOpen = navMenu?.classList.toggle('open');
      mobileBtn.setAttribute('aria-expanded', isOpen ? 'true' : 'false');
    });

    document.addEventListener('click', (e) => {
      if (navMenu?.classList.contains('open') && !navMenu.contains(e.target) && !mobileBtn?.contains(e.target)) {
        navMenu.classList.remove('open');
        mobileBtn?.setAttribute('aria-expanded', 'false');
      }
    });

    // Wallet Connect
    document.getElementById('btn-wallet')?.addEventListener('click', async () => {
      try {
        await connectWallet();
        showToast(`Connected: ${shortAddr(state.account)}`);
        await loadWallet();
        render(true);
      } catch (err) {
        showToast(walletError(err));
      }
    });

    if (window.ethereum?.on) {
      window.ethereum.on('accountsChanged', async (accounts) => {
        setAccount(accounts && accounts[0]);
        await loadWallet();
        render(true);
      });
    }

    // Reconnect silently if the site was already allowed.
    if (window.ethereum) {
      window.ethereum.request({ method: 'eth_accounts' }).then(async (accounts) => {
        if (accounts && accounts[0]) {
          setAccount(accounts[0]);
          await loadWallet();
          render(true);
        }
      }).catch(() => {});
    }

    // Hashchange listener
    window.addEventListener('hashchange', () => render());

    // Initial render, then fill in what Sepolia says, and keep it fresh while the tab is visible.
    render();
    refreshLive();
    setInterval(() => {
      if (document.visibilityState === 'visible' && !state.busy) refreshLive(true);
    }, 60000);
  }

  document.addEventListener('DOMContentLoaded', init);
})();
