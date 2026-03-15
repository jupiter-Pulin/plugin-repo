#!/usr/bin/env node
'use strict';

// ---------------------------------------------------------------------------
// scan-holders.js — Scan ERC-20 token holders via JSON-RPC
//
// Modes:
//   top-N (default)  — Find top N holders by balance (descending)
//   range            — Find N holders with balance in [min, max]
//
// Usage:
//   node scan-holders.js --target-address 0x... [options]
//
// Options:
//   --target-address <addr>   Token contract address (required)
//   --rpc-url <url>           JSON-RPC endpoint (default: public eth)
//   --network <id>            Preset RPC by network id
//   --min <number>            Minimum balance (human-readable, e.g. 10000)
//   --max <number>            Maximum balance (human-readable, e.g. 50000)
//   --limit <number>          Number of results (default: 10)
//   --decimals <number>       Token decimals (auto-detected if omitted)
//   --block-range <number>    Blocks per getLogs call (default: 500)
//   --max-scan <number>       Max blocks to scan back (default: 50000)
//   --json                    Output as JSON
// ---------------------------------------------------------------------------

const TRANSFER_TOPIC = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';
const BALANCE_OF_SELECTOR = '0x70a08231';
const DECIMALS_SELECTOR = '0x313ce567';
const SYMBOL_SELECTOR = '0x95d89b41';
const ZERO_ADDR = '0x0000000000000000000000000000000000000000';

const NETWORK_RPC = {
  eth: 'https://eth.llamarpc.com',
  bsc: 'https://bsc-dataseed1.binance.org',
  polygon: 'https://polygon-rpc.com',
  arb: 'https://arb1.arbitrum.io/rpc',
  op: 'https://mainnet.optimism.io',
  base: 'https://mainnet.base.org',
  avax: 'https://api.avax.network/ext/bc/C/rpc',
};

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------
function argVal(flag) {
  const i = process.argv.indexOf(flag);
  return i > -1 && i + 1 < process.argv.length ? process.argv[i + 1] : null;
}

const TARGET_ADDRESS = argVal('--target-address');
const NETWORK = argVal('--network') || 'eth';
const RPC_URL = argVal('--rpc-url') || NETWORK_RPC[NETWORK] || NETWORK_RPC.eth;
const MIN_RAW = argVal('--min');
const MAX_RAW = argVal('--max');
const LIMIT = parseInt(argVal('--limit') || '10', 10);
const DECIMALS_OVERRIDE = argVal('--decimals');
const BLOCK_RANGE = parseInt(argVal('--block-range') || '500', 10);
const MAX_SCAN = parseInt(argVal('--max-scan') || '50000', 10);
const JSON_OUTPUT = process.argv.includes('--json');

if (!TARGET_ADDRESS) {
  console.error('Error: --target-address is required');
  console.error('Usage: node scan-holders.js --target-address 0x...');
  process.exit(1);
}

const IS_RANGE_MODE = MIN_RAW != null || MAX_RAW != null;

// ---------------------------------------------------------------------------
// RPC helpers
// ---------------------------------------------------------------------------
let rpcId = 1;

async function rpcCall(method, params) {
  const res = await fetch(RPC_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: rpcId++, method, params }),
  });
  const json = await res.json();
  if (json.error) throw new Error(`RPC error [${method}]: ${JSON.stringify(json.error)}`);
  return json.result;
}

async function getLatestBlock() {
  const hex = await rpcCall('eth_blockNumber', []);
  return BigInt(hex);
}

async function getTransferLogs(fromBlock, toBlock) {
  return rpcCall('eth_getLogs', [{
    address: TARGET_ADDRESS,
    fromBlock: '0x' + fromBlock.toString(16),
    toBlock: '0x' + toBlock.toString(16),
    topics: [TRANSFER_TOPIC],
  }]);
}

async function callContract(data) {
  return rpcCall('eth_call', [{ to: TARGET_ADDRESS, data }, 'latest']);
}

async function getBalance(address) {
  const paddedAddr = '0x' + address.slice(2).padStart(64, '0');
  const data = BALANCE_OF_SELECTOR + paddedAddr.slice(2);
  const result = await callContract(data);
  return BigInt(result);
}

async function getDecimals() {
  if (DECIMALS_OVERRIDE != null) return parseInt(DECIMALS_OVERRIDE, 10);
  try {
    const result = await callContract(DECIMALS_SELECTOR);
    return Number(BigInt(result));
  } catch {
    return 18; // fallback
  }
}

async function getSymbol() {
  try {
    const result = await callContract(SYMBOL_SELECTOR);
    // Decode ABI-encoded string
    const hex = result.slice(2);
    if (hex.length < 128) {
      // Non-standard: raw bytes (e.g. MKR returns bytes32)
      const clean = hex.replace(/00+$/g, '');
      return Buffer.from(clean, 'hex').toString('utf8').trim() || 'TOKEN';
    }
    const len = parseInt(hex.slice(64, 128), 16);
    const strHex = hex.slice(128, 128 + len * 2);
    return Buffer.from(strHex, 'hex').toString('utf8') || 'TOKEN';
  } catch {
    return 'TOKEN';
  }
}

function formatBalance(raw, decimals) {
  const str = raw.toString();
  if (decimals === 0) return str;
  if (str.length <= decimals) return '0.' + str.padStart(decimals, '0');
  return str.slice(0, str.length - decimals) + '.' + str.slice(str.length - decimals);
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
async function main() {
  const [decimals, symbol, latestBlock] = await Promise.all([
    getDecimals(),
    getSymbol(),
    getLatestBlock(),
  ]);

  const unit = 10n ** BigInt(decimals);
  const minBalance = MIN_RAW != null ? BigInt(Math.floor(parseFloat(MIN_RAW))) * unit : null;
  const maxBalance = MAX_RAW != null ? BigInt(Math.floor(parseFloat(MAX_RAW))) * unit : null;

  if (!JSON_OUTPUT) {
    console.error(`Token: ${symbol} (${TARGET_ADDRESS})`);
    console.error(`Decimals: ${decimals}`);
    console.error(`Network: ${NETWORK} | RPC: ${RPC_URL}`);
    console.error(`Latest block: ${latestBlock}`);
    if (IS_RANGE_MODE) {
      console.error(`Mode: range [${MIN_RAW || '0'} - ${MAX_RAW || '∞'}] ${symbol}`);
    } else {
      console.error(`Mode: top-${LIMIT} holders`);
    }
    console.error('---');
  }

  const addressBalances = new Map();
  const checked = new Set();
  let toBlock = latestBlock;
  const stopBlock = latestBlock - BigInt(MAX_SCAN);

  while (toBlock > stopBlock) {
    const fromBlock = toBlock - BigInt(BLOCK_RANGE) + 1n;

    if (!JSON_OUTPUT) {
      console.error(`Scanning blocks ${fromBlock}-${toBlock}...`);
    }

    let logs;
    try {
      logs = await getTransferLogs(fromBlock > 0n ? fromBlock : 0n, toBlock);
    } catch (e) {
      if (!JSON_OUTPUT) console.error(`  getLogs failed: ${e.message}`);
      toBlock = fromBlock - 1n;
      continue;
    }

    // Extract unique addresses
    const candidates = new Set();
    for (const log of logs) {
      if (log.topics && log.topics.length >= 3) {
        const from = '0x' + log.topics[1].slice(26);
        const to = '0x' + log.topics[2].slice(26);
        if (from !== ZERO_ADDR) candidates.add(from.toLowerCase());
        if (to !== ZERO_ADDR) candidates.add(to.toLowerCase());
      }
    }

    // Check balances
    for (const addr of candidates) {
      if (checked.has(addr)) continue;
      checked.add(addr);

      try {
        const balance = await getBalance(addr);
        if (balance === 0n) continue;

        if (IS_RANGE_MODE) {
          const aboveMin = minBalance == null || balance >= minBalance;
          const belowMax = maxBalance == null || balance <= maxBalance;
          if (aboveMin && belowMax) {
            addressBalances.set(addr, balance);
            if (!JSON_OUTPUT) {
              console.error(`  [${addressBalances.size}/${LIMIT}] ${addr} - ${formatBalance(balance, decimals)} ${symbol}`);
            }
            if (addressBalances.size >= LIMIT) break;
          }
        } else {
          // top-N: collect all, sort later
          addressBalances.set(addr, balance);
        }
      } catch {
        // skip failed balance checks
      }
    }

    // Early exit for range mode
    if (IS_RANGE_MODE && addressBalances.size >= LIMIT) break;

    // For top-N: if we have enough candidates (3x limit), we can stop scanning
    if (!IS_RANGE_MODE && addressBalances.size >= LIMIT * 3) break;

    toBlock = fromBlock - 1n;
  }

  // ---------------------------------------------------------------------------
  // Build results
  // ---------------------------------------------------------------------------
  let results;
  if (IS_RANGE_MODE) {
    results = [...addressBalances.entries()]
      .map(([address, balance]) => ({ address, balance, formatted: formatBalance(balance, decimals) }));
  } else {
    results = [...addressBalances.entries()]
      .sort((a, b) => (b[1] > a[1] ? 1 : b[1] < a[1] ? -1 : 0))
      .slice(0, LIMIT)
      .map(([address, balance]) => ({ address, balance, formatted: formatBalance(balance, decimals) }));
  }

  // ---------------------------------------------------------------------------
  // Output
  // ---------------------------------------------------------------------------
  if (JSON_OUTPUT) {
    const output = {
      token: { address: TARGET_ADDRESS, symbol, decimals },
      network: NETWORK,
      mode: IS_RANGE_MODE ? 'range' : 'top',
      range: IS_RANGE_MODE ? { min: MIN_RAW || null, max: MAX_RAW || null } : null,
      scanned_addresses: checked.size,
      results: results.map(r => ({
        address: r.address,
        balance: r.formatted,
      })),
    };
    console.log(JSON.stringify(output, null, 2));
  } else {
    console.log('');
    console.log(`## ${symbol} Holder Scan Results`);
    console.log('');
    console.log(`| # | Address | Balance (${symbol}) |`);
    console.log('|---|---------|---------|');
    results.forEach((r, i) => {
      console.log(`| ${i + 1} | \`${r.address}\` | ${r.formatted} |`);
    });
    console.log('');
    console.log(`Scanned ${checked.size} unique addresses, found ${results.length} results.`);
  }
}

main().catch(err => {
  console.error(`Fatal: ${err.message}`);
  process.exit(2);
});
