---
name: defi-onchain-balance
description: "Query on-chain ERC-20 token holder balances via script. Use when: finding top holders, querying token balances in a range, on-chain balance lookup. Not for: transaction decoding (use tx-decode), code review (use codex-code-review). Output: holder address list with balances."
allowed-tools: Bash(node:*), Agent, Read
context: fork
---

# DeFi On-Chain Balance Skill

## Trigger

- Keywords: on-chain balance, token holders, holder scan, balance query, top holders, ERC-20 balance

## When NOT to Use

- Transaction decoding or fund flow analysis (use `/tx-decode`)
- Code review or code exploration
- Non-EVM chains

## Workflow

```
Main Agent (you)
  │
  ├─ 1. Parse arguments: targetAddress, rpc-url, min, max, limit, network
  │
  ├─ 2. Run script: node skills/defi-onchain-balance/scripts/scan-holders.js
  │     └─ Script does ALL the work (scan logs, check balances, format output)
  │
  ├─ 3a. Script succeeds → Present output directly to user
  │
  └─ 3b. Script fails → AI intervenes:
        ├─ Read script stderr for error cause
        └─ Spawn Agent (general-purpose) to query on-chain via alternative method
```

## Main Agent Rules

| Rule | Description |
|------|-------------|
| ✅ Parse arguments | Extract target address, network, range, limit from user input |
| ✅ Run script | Execute `scan-holders.js` with parsed arguments |
| ✅ Pass through output | Present script output directly — DO NOT re-interpret |
| ❌ Do NOT modify results | Script output is authoritative |
| ❌ Do NOT add analysis | Only report what the script returns |
| ⚠️ Intervene on failure | If script errors, AI diagnoses and uses subagent fallback |

## Script Contract

| Field | Value |
|-------|-------|
| Path | `skills/defi-onchain-balance/scripts/scan-holders.js` |
| Runtime | Node.js (native fetch, zero deps) |
| Input | CLI flags (see below) |
| Output | Markdown table (stdout) or JSON (`--json`) |
| Errors | stderr + exit code 1 (missing args) or 2 (fatal) |

### Script Arguments

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--target-address <addr>` | ✅ | — | ERC-20 token contract address |
| `--rpc-url <url>` | ❌ | network default | JSON-RPC endpoint |
| `--network <id>` | ❌ | `eth` | eth, bsc, polygon, arb, op, base, avax |
| `--min <number>` | ❌ | — | Minimum balance (human-readable) |
| `--max <number>` | ❌ | — | Maximum balance (human-readable) |
| `--limit <number>` | ❌ | `10` | Number of results |
| `--decimals <number>` | ❌ | auto-detect | Token decimals override |
| `--block-range <number>` | ❌ | `500` | Blocks per getLogs batch |
| `--max-scan <number>` | ❌ | `50000` | Max blocks to scan back |
| `--json` | ❌ | — | Output as JSON instead of Markdown |

### Modes

| Mode | Trigger | Behavior |
|------|---------|----------|
| **top-N** | No `--min`/`--max` | Collect addresses, sort by balance desc, return top N |
| **range** | `--min` and/or `--max` set | Return first N addresses with balance in range |

## Fallback (Script Failure)

If the script exits with error:

1. Read stderr output to identify cause
2. Spawn a `general-purpose` Agent with prompt:
   - "Query ERC-20 balanceOf for token {address} on {network}"
   - Include the RPC URL and target addresses if available
   - Ask agent to use `eth_call` directly via `curl` or `node`

## Verification

- [ ] Script runs: `node scripts/scan-holders.js --target-address 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 --limit 3`
- [ ] Output contains address + balance table
- [ ] Range mode works: `--min 10000 --max 50000`
- [ ] JSON output works: `--json`

## Examples

```bash
# Top 10 USDC holders (default)
/defi-onchain-balance --target-address 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

# Top 5 USDT holders on Ethereum
/defi-onchain-balance --target-address 0xdAC17F958D2ee523a2206206994597C13D831ec7 --limit 5

# USDC holders with balance 10000-50000
/defi-onchain-balance --target-address 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 --min 10000 --max 50000

# Custom RPC
/defi-onchain-balance --target-address 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 --rpc-url https://v5-rpc-proxy.onekey-internal.com/eth/

# BSC token holders as JSON
/defi-onchain-balance --target-address 0x55d398326f99059fF775485246999027B3197955 --network bsc --json
```
