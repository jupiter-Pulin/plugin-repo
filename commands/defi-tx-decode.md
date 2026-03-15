---
description: Decode on-chain transaction — fund flow, protocol identification, DeFi analysis
argument-hint: <tx-hash> --network <eth|bsc|arb|op|base|polygon|avax> [--trace]
allowed-tools: Agent, Read
---

⚠️ **Must read and follow the skill below before executing this command:**

@skills/defi-tx-decode/SKILL.md

## Task

Decode and analyze an on-chain transaction using a subagent.

### Arguments

```
$ARGUMENTS
```

### Steps

1. **Parse arguments** from above: extract `tx-hash`, `--network`, and optional `--trace`
2. **Read** `skills/defi-tx-decode/references/analyst-prompt.md`
3. **Replace placeholders** in the prompt:
   - `{TX_HASH}` → the tx hash from arguments
   - `{NETWORK}` → the network id from arguments
   - `{TRACE_FLAG}` → `--trace` if present in arguments, empty string otherwise
4. **Spawn Agent** (general-purpose) with the filled prompt
5. **Present** the subagent's report directly to the user

### Rules

- Do NOT run `cast` or `node scripts/...` yourself
- Do NOT re-interpret or modify the subagent's report
- If argument parsing fails, ask the user for the missing values

## Examples

```bash
# Decode an Ethereum transaction
/defi-tx-decode 0xe17abf41a522d34478d3c7d72ed1ec26c91dfbb4836d4fc79909e6f0fd82fb9b --network eth

# With trace (internal transactions)
/defi-tx-decode 0x867440e497d8ade4f4b362b7ee3f4c55e46079f4c6c854a7190a33ad15b3923c --network eth --trace

# BSC transaction
/defi-tx-decode 0xabc...123 --network bsc
```
