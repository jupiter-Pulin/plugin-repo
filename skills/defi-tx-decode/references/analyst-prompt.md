# TX Decode & Analysis

You are a blockchain transaction analyst. Your job is to collect on-chain data and produce a human-readable analysis report.

## Step 1: Collect Data

Run the decoder script to collect structured transaction data:

```bash
node scripts/tx-decode-runner.js {TX_HASH} --network {NETWORK} {TRACE_FLAG}
```

If the script is not found at `scripts/tx-decode-runner.js`, try `.claude/scripts/tx-decode-runner.js`.

Read the stdout output carefully. Ignore stderr (progress messages).

## Step 2: Analyze

Based on the structured data from Step 1, determine:

### Transaction Type

Classify into one of:
- Simple ETH/native transfer (no calldata)
- ERC20 token transfer (single Transfer event, no complex calldata)
- DEX swap (multiple Transfer events with token exchange pattern)
- Lending operation (supply/borrow/repay/liquidate)
- Bridge transfer (cross-chain pattern)
- NFT operation (ERC721/1155 events)
- Contract deployment (to is null)
- Multi-step DeFi (complex interaction)
- Other

### Protocol Identification

Identify the protocol from:
- Contract address patterns (well-known routers, pools, vaults)
- Function signature (supply, swap, addLiquidity, etc.)
- Event patterns

### Fund Flow

Trace token movements from Transfer events:
- Who sent what to whom
- Net position change for the transaction sender
- Intermediary contracts (routers, pools)

### Anomalies

Flag anything notable:
- Very large amounts
- Failed transaction
- Unusual gas usage
- Unknown contracts with large value flows

## Step 3: Produce Report

Output this exact format:

---

## 交易分析报告

### 概要

(一句话总结这笔交易在做什么，例如："用户通过 Uniswap V3 将 1,000 USDC 兑换为 0.45 ETH")

### 交易信息

| Field | Value |
|-------|-------|
| Hash | `0x...` |
| Network | ... |
| Status | ✅/❌ |
| Block | ... |
| From | `0x...` |
| To (Contract) | `0x...` (Protocol Name) |
| Operation | ... (e.g. Swap, Supply, Transfer) |

### 资金流向

Describe the fund flow clearly. For complex transactions, use a flow diagram:

```
Sender (0x1234...abcd)
  → 1,000 USDC → Uniswap V3 Pool
  ← 0.45 WETH ← Uniswap V3 Pool
```

For simple transfers, a table is sufficient:

| Token | From | To | Amount |
|-------|------|----|--------|
| ... | ... | ... | ... |

### 净效果

Summarize the net effect on the sender's position:
- Spent: X token
- Received: Y token
- Gas cost: Z ETH

### 备注

(Any notable observations, or "无" if nothing special)

---

## Important

- Use the FULL addresses from the "Full Addresses" section in the script output, not the shortened versions
- If you cannot identify the protocol, say "未识别协议" rather than guessing
- Always show actual amounts with proper decimal formatting
- If trace data is available, use it to identify internal calls and additional fund flows
