---
name: defi-tx-decode
description: "Decode on-chain transaction with fund flow analysis via subagent. Use when: analyzing blockchain transactions, tracing fund flows, decoding DeFi interactions. Not for: general code review (use codex-code-review), code exploration (use code-explore). Output: transaction analysis report."
allowed-tools: Agent, Read
context: fork
---

# DeFi TX Decode Skill

## Trigger

- Keywords: defi tx decode, transaction decode, decode tx, trace transaction, fund flow, tx analysis, defi analysis

## When NOT to Use

- Code review or code exploration
- Non-EVM chains

## Workflow

```
Main Agent (you)
  │
  ├─ 1. Parse user arguments (hash, network, trace)
  │
  ├─ 2. Read references/analyst-prompt.md
  │
  ├─ 3. Replace placeholders: {TX_HASH}, {NETWORK}, {TRACE_FLAG}
  │
  ├─ 4. Spawn Agent (general-purpose) with filled prompt
  │
  └─ 5. Present subagent report to user — DO NOT re-interpret
```

## Main Agent Rules

| Rule | Description |
|------|-------------|
| ❌ Do NOT run `cast` yourself | Subagent runs the script |
| ❌ Do NOT interpret tx data | Subagent produces the analysis |
| ❌ Do NOT modify subagent report | Present it as-is |
| ✅ Parse arguments | Extract hash, network, trace from user input |
| ✅ Spawn subagent | Use Agent tool with filled prompt |
| ✅ Pass through report | Show subagent output to user |

## Argument Parsing

| Argument | Required | Description |
|----------|----------|-------------|
| `<tx-hash>` | ✅ | 66-char hex string starting with 0x |
| `--network <id>` | ✅ | eth, bsc, polygon, arb, op, base, avax |
| `--trace` | ❌ | Enable internal transaction trace (slow, needs archive node) |

## Subagent Prompt

Read `skills/defi-tx-decode/references/analyst-prompt.md` and replace:

- `{TX_HASH}` → the actual tx hash
- `{NETWORK}` → the network id (e.g. `eth`)
- `{TRACE_FLAG}` → `--trace` if user requested, empty string otherwise

## Supported Networks

| ID | Network | ChainId |
|----|---------|---------|
| eth | Ethereum | 1 |
| bsc | BNB Chain | 56 |
| polygon | Polygon | 137 |
| arb | Arbitrum | 42161 |
| op | Optimism | 10 |
| base | Base | 8453 |
| avax | Avalanche | 43114 |

## Output

Subagent returns a structured report containing:

- Transaction summary (one sentence)
- Protocol identification
- Fund flow analysis
- Anomaly notes

## Verification

- [ ] Script runs without errors for a known tx hash
- [ ] Subagent report includes protocol identification
- [ ] Token amounts are correctly formatted with decimals
- [ ] Full addresses are available in collapsed section

## Examples

```bash
# Simple ETH transfer
/defi-tx-decode 0xabc...123 --network eth

# DeFi interaction with trace
/defi-tx-decode 0xdef...456 --network arb --trace

# BSC token transfer
/defi-tx-decode 0x789...abc --network bsc
```

## Related

| Command/Skill | Difference |
|---------------|------------|
| `cast tx` (raw) | No interpretation, just raw data |
| Block explorers | Web-based, no AI analysis |
