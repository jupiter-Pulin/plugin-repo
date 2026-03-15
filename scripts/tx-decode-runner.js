#!/usr/bin/env node
/**
 * tx-decode-runner.js
 * Collects on-chain transaction data using cast (Foundry) and outputs
 * structured Markdown for AI analysis.
 *
 * Usage:
 *   node tx-decode-runner.js <tx-hash> --network <eth|bsc|arb|...> [--trace]
 *
 * Output: Structured Markdown to stdout
 * Progress: stderr
 */

const { runCapture } = require('./lib/utils');

// --- Network Configuration (hardcoded internal proxy) ---
const NETWORKS = {
  eth: { chainId: 1, name: 'Ethereum', rpc: 'https://v5-rpc-proxy.onekey-internal.com/eth/' },
  bsc: { chainId: 56, name: 'BNB Chain', rpc: 'https://v5-rpc-proxy.onekey-internal.com/bsc/' },
  polygon: { chainId: 137, name: 'Polygon', rpc: 'https://v5-rpc-proxy.onekey-internal.com/polygon/' },
  arb: { chainId: 42161, name: 'Arbitrum', rpc: 'https://v5-rpc-proxy.onekey-internal.com/arb/' },
  op: { chainId: 10, name: 'Optimism', rpc: 'https://v5-rpc-proxy.onekey-internal.com/op/' },
  base: { chainId: 8453, name: 'Base', rpc: 'https://v5-rpc-proxy.onekey-internal.com/base/' },
  avax: { chainId: 43114, name: 'Avalanche', rpc: 'https://v5-rpc-proxy.onekey-internal.com/avax/' },
};

// ERC20 Transfer(address,address,uint256) event topic
const TRANSFER_TOPIC =
  '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function shortAddr(addr) {
  if (!addr || addr.length < 12) return addr || '(none)';
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}

/** Convert hex-or-decimal string to BigInt. */
function toBigInt(val) {
  if (!val) return 0n;
  if (typeof val === 'number') return BigInt(val);
  const s = String(val).trim();
  if (s === '' || s === '0x') return 0n;
  try {
    return BigInt(s);
  } catch {
    return 0n;
  }
}

/** Format a raw integer amount with `decimals` decimal places. */
function formatAmount(raw, decimals) {
  const d = parseInt(decimals, 10);
  if (isNaN(d) || d === 0) return String(raw);
  const str = toBigInt(raw).toString();
  let intPart, fracPart;
  if (str.length <= d) {
    const padded = str.padStart(d + 1, '0');
    intPart = padded.slice(0, padded.length - d);
    fracPart = padded.slice(padded.length - d).replace(/0+$/, '');
  } else {
    intPart = str.slice(0, str.length - d);
    fracPart = str.slice(str.length - d).replace(/0+$/, '');
  }
  const formatted = intPart.replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  return fracPart ? `${formatted}.${fracPart}` : formatted;
}

function progress(msg) {
  process.stderr.write(`> ${msg}\n`);
}

// ---------------------------------------------------------------------------
// Cast wrappers
// ---------------------------------------------------------------------------

async function castJson(args) {
  const r = await runCapture('cast', args);
  if (r.code !== 0) return { error: r.stderr.trim() || `exit ${r.code}`, raw: null };
  try {
    return { error: null, raw: JSON.parse(r.stdout) };
  } catch {
    return { error: `JSON parse failed`, raw: null };
  }
}

async function castText(args) {
  const r = await runCapture('cast', args);
  if (r.code !== 0) return null;
  return r.stdout.trim();
}

// ---------------------------------------------------------------------------
// Token info cache
// ---------------------------------------------------------------------------

const tokenCache = {};

async function getTokenInfo(address, rpc) {
  if (tokenCache[address]) return tokenCache[address];
  const [symbol, decimals] = await Promise.all([
    castText(['call', address, 'symbol()(string)', '--rpc-url', rpc]),
    castText(['call', address, 'decimals()(uint8)', '--rpc-url', rpc]),
  ]);
  const info = {
    symbol: symbol || 'UNKNOWN',
    decimals: decimals || '18',
  };
  tokenCache[address] = info;
  return info;
}

// ---------------------------------------------------------------------------
// Transfer event parsing
// ---------------------------------------------------------------------------

function decodeTransferLog(log) {
  if (!log.topics || log.topics.length < 3) return null;
  if (log.topics[0].toLowerCase() !== TRANSFER_TOPIC) return null;
  const from = '0x' + log.topics[1].slice(26);
  const to = '0x' + log.topics[2].slice(26);
  const value = log.data && log.data !== '0x' ? toBigInt(log.data).toString() : '0';
  return { token: log.address, from, to, value };
}

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------

function parseArgs(argv) {
  const args = { hash: null, network: null, trace: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === '--network' && argv[i + 1]) {
      args.network = argv[i + 1].toLowerCase();
      i++;
    } else if (k === '--trace') {
      args.trace = true;
    } else if (k.startsWith('0x') && k.length === 66) {
      args.hash = k;
    }
  }
  return args;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv.slice(2));

  if (!args.hash) {
    process.stderr.write(
      `[ERROR] Missing tx hash.\nUsage: tx-decode-runner.js <tx-hash> --network <${Object.keys(NETWORKS).join('|')}> [--trace]\n`
    );
    process.exit(2);
  }
  if (!args.network || !NETWORKS[args.network]) {
    process.stderr.write(
      `[ERROR] Unknown network: ${args.network || '(none)'}. Available: ${Object.keys(NETWORKS).join(', ')}\n`
    );
    process.exit(2);
  }

  // Check cast
  const ver = await castText(['--version']);
  if (!ver) {
    process.stderr.write('[ERROR] cast (Foundry) not found. Install: https://getfoundry.sh\n');
    process.exit(127);
  }

  const net = NETWORKS[args.network];
  const rpc = net.rpc;
  const lines = [];

  lines.push('# TX Decode Report');
  lines.push('');

  // --- Step 1: Fetch transaction ---
  progress(`Fetching tx ${shortAddr(args.hash)} on ${net.name}...`);
  const tx = await castJson(['tx', args.hash, '--rpc-url', rpc, '--json']);
  if (tx.error) {
    lines.push(`## Error`);
    lines.push(`Failed to fetch transaction: ${tx.error}`);
    process.stdout.write(lines.join('\n'));
    process.exit(1);
  }
  const txd = tx.raw;

  // --- Step 2: Fetch receipt ---
  progress('Fetching receipt...');
  const receipt = await castJson(['receipt', args.hash, '--rpc-url', rpc, '--json']);
  const rcpt = receipt.raw; // may be null

  // --- Step 3: Decode function ---
  let funcDecoded = null;
  const input = txd.input || '';
  if (input.length >= 10 && input !== '0x') {
    progress(`Decoding selector ${input.slice(0, 10)}...`);
    funcDecoded = await castText(['4byte-decode', input]);
  }

  // --- Step 4: Parse Transfer events ---
  const transfers = [];
  const allLogs = (rcpt && rcpt.logs) || [];
  for (const log of allLogs) {
    const t = decodeTransferLog(log);
    if (t) transfers.push(t);
  }

  // --- Step 5: Fetch token info ---
  const uniqueTokens = [...new Set(transfers.map(t => t.token))];
  if (uniqueTokens.length > 0) {
    progress(`Fetching info for ${uniqueTokens.length} token(s)...`);
    await Promise.all(uniqueTokens.map(addr => getTokenInfo(addr, rpc)));
  }

  // --- Format output ---

  // Basic Info
  const ethValue = formatAmount(toBigInt(txd.value).toString(), '18');
  const status = rcpt
    ? rcpt.status === '0x1' || rcpt.status === 1 || rcpt.status === '1'
      ? '✅ Success'
      : '❌ Failed'
    : '⚠️ Unknown (receipt failed)';
  const blockNum = txd.blockNumber || txd.block_number || '';
  const gasUsed = rcpt ? (rcpt.gasUsed || rcpt.gas_used || '') : '';
  const gasPrice = txd.effectiveGasPrice || txd.effective_gas_price ||
    (rcpt && (rcpt.effectiveGasPrice || rcpt.effective_gas_price)) || '';

  lines.push('## Basic Info');
  lines.push('| Field | Value |');
  lines.push('|-------|-------|');
  lines.push(`| Hash | \`${args.hash}\` |`);
  lines.push(`| Network | ${net.name} (chainId: ${net.chainId}) |`);
  lines.push(`| Status | ${status} |`);
  lines.push(`| Block | ${toBigInt(blockNum).toString()} |`);
  lines.push(`| From | \`${txd.from}\` |`);
  lines.push(`| To | \`${txd.to || '(contract creation)'}\` |`);
  lines.push(`| Value | ${ethValue} ETH |`);

  if (funcDecoded) {
    // First line of 4byte-decode output is the function signature
    const sig = funcDecoded.split('\n')[0].replace(/^\d+\)\s*/, '').trim();
    lines.push(`| Function | \`${sig}\` |`);
  } else if (input.length >= 10 && input !== '0x') {
    lines.push(`| Selector | \`${input.slice(0, 10)}\` (unknown) |`);
  } else if (input === '0x' || input === '') {
    lines.push(`| Type | Simple transfer (no calldata) |`);
  }

  if (gasUsed) {
    lines.push(`| Gas Used | ${toBigInt(gasUsed).toLocaleString()} |`);
  }
  if (gasPrice) {
    lines.push(`| Gas Price | ${formatAmount(toBigInt(gasPrice).toString(), '9')} Gwei |`);
  }
  lines.push('');

  // Function decode detail
  if (funcDecoded) {
    lines.push('## Decoded Function Call');
    lines.push('```');
    // Truncate if too long
    const decLines = funcDecoded.split('\n');
    if (decLines.length > 30) {
      lines.push(decLines.slice(0, 30).join('\n'));
      lines.push(`... (${decLines.length} lines total)`);
    } else {
      lines.push(funcDecoded);
    }
    lines.push('```');
    lines.push('');
  }

  // Token Transfers
  lines.push('## Token Transfers');
  if (transfers.length > 0) {
    lines.push('| # | Token | From | To | Amount |');
    lines.push('|---|-------|------|----|--------|');
    for (let i = 0; i < transfers.length; i++) {
      const t = transfers[i];
      const info = tokenCache[t.token] || { symbol: 'UNKNOWN', decimals: '18' };
      const amount = formatAmount(t.value, info.decimals);
      lines.push(
        `| ${i + 1} | ${info.symbol} (\`${shortAddr(t.token)}\`) | \`${shortAddr(t.from)}\` | \`${shortAddr(t.to)}\` | ${amount} |`
      );
    }
    lines.push('');

    // Full address reference
    lines.push('<details><summary>Full Addresses</summary>');
    lines.push('');
    const allAddrs = new Set();
    allAddrs.add(txd.from);
    if (txd.to) allAddrs.add(txd.to);
    for (const t of transfers) {
      allAddrs.add(t.from);
      allAddrs.add(t.to);
      allAddrs.add(t.token);
    }
    for (const addr of allAddrs) {
      const info = tokenCache[addr];
      const label = info ? ` (${info.symbol})` : '';
      lines.push(`- \`${addr}\`${label}`);
    }
    lines.push('');
    lines.push('</details>');
    lines.push('');
  } else {
    lines.push('(No ERC20 Transfer events found)');
    lines.push('');
  }

  // Other events summary
  const nonTransferLogs = allLogs.filter(
    l => !l.topics || !l.topics[0] || l.topics[0].toLowerCase() !== TRANSFER_TOPIC
  );
  if (nonTransferLogs.length > 0) {
    lines.push('## Other Events');
    const sigCounts = {};
    for (const l of nonTransferLogs) {
      const sig = (l.topics && l.topics[0]) || '(anonymous)';
      sigCounts[sig] = (sigCounts[sig] || 0) + 1;
    }
    lines.push(`${nonTransferLogs.length} non-Transfer event(s) emitted:`);
    lines.push('');
    lines.push('| Event Topic | Emitter | Count |');
    lines.push('|-------------|---------|-------|');
    for (const [sig, count] of Object.entries(sigCounts)) {
      const emitters = nonTransferLogs
        .filter(l => (l.topics && l.topics[0]) === sig || (!l.topics && sig === '(anonymous)'))
        .map(l => l.address);
      const uniqueEmitters = [...new Set(emitters)];
      lines.push(
        `| \`${sig.slice(0, 10)}...\` | \`${shortAddr(uniqueEmitters[0])}\`${uniqueEmitters.length > 1 ? ` +${uniqueEmitters.length - 1}` : ''} | ${count} |`
      );
    }
    lines.push('');
  }

  // Raw input (truncated)
  if (input.length > 10) {
    lines.push('## Raw Input');
    lines.push('```');
    if (input.length > 200) {
      lines.push(`${input.slice(0, 200)}... (${input.length} chars total)`);
    } else {
      lines.push(input);
    }
    lines.push('```');
    lines.push('');
  }

  // Trace (optional)
  if (args.trace) {
    progress('Running trace (may take a while, requires archive node)...');
    const trace = await castText(['run', args.hash, '--rpc-url', rpc]);
    lines.push('## Trace');
    if (trace) {
      lines.push('```');
      const traceLines = trace.split('\n');
      if (traceLines.length > 150) {
        lines.push(traceLines.slice(0, 150).join('\n'));
        lines.push(`\n... (${traceLines.length} lines total, truncated)`);
      } else {
        lines.push(trace);
      }
      lines.push('```');
    } else {
      lines.push('(trace failed — archive node may be required)');
    }
    lines.push('');
  }

  process.stdout.write(lines.join('\n'));
}

main().catch(e => {
  process.stdout.write(
    `# TX Decode\n\n❌ runner crashed: ${String((e && e.stack) || e)}\n`
  );
  process.exit(1);
});
