---
description: Query on-chain ERC-20 token holder balances — top holders or balance range scan
argument-hint: --target-address <0x...> [--min N] [--max N] [--limit N] [--network eth|bsc|arb|op|base|polygon|avax] [--rpc-url <url>]
allowed-tools: Bash(node:*), Agent, Read
---

⚠️ **Must read and follow the skill below before executing this command:**

@skills/defi-onchain-balance/SKILL.md

## Task

Query ERC-20 token holder balances using the scan script.

### Arguments

```
$ARGUMENTS
```

### Steps

1. **Parse arguments** from above: extract `--target-address`, `--network`, `--rpc-url`, `--min`, `--max`, `--limit`
2. **Run script**:
   ```bash
   node skills/defi-onchain-balance/scripts/scan-holders.js $PARSED_ARGS
   ```
3. **On success** → Present the script output directly to user
4. **On failure** → Read stderr, diagnose, spawn Agent (general-purpose) as fallback

### Rules

- Do NOT modify or re-interpret the script output
- Do NOT add your own analysis — just present results
- Only intervene if the script exits with error (non-zero exit code)
- If `--target-address` is missing, ask the user for it

## Examples

```bash
# Default: top 10 holders
/defi-onchain-balance --target-address 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48

# Range query
/defi-onchain-balance --target-address 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 --min 10000 --max 50000

# Custom RPC + limit
/defi-onchain-balance --target-address 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 --rpc-url https://v5-rpc-proxy.onekey-internal.com/eth/ --limit 20

# Different network
/defi-onchain-balance --target-address 0x55d398326f99059fF775485246999027B3197955 --network bsc --limit 5
```
