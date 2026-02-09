# Save Funds Scripts

This folder contains helper scripts to produce calldata for Safe Multisig transactions and a deploy command for the
mainnet Save Funds stack.

**Deposit 100 USDC and Invest 100% into UniV3 Strategy**

Notes:
- `buildVaultInvestCalldata.js` prints calldata to stdout (console). It does not write to a file.
- USDC has 6 decimals, so 100 USDC = `100000000`.

Steps:
1. Safe: approve `SFVault` to spend `100000000` USDC.
2. Safe: call `SFVault.deposit(100000000, <SAFE_ADDRESS>)`.
3. Build calldata for `SFVault.investIntoStrategy(...)` (full amount into UniV3).
   You can pass `--chain arb-one` or `--chain arb-sepolia` to avoid typing token/strategy addresses.

```bash
node scripts/save-funds/buildVaultInvestCalldata.js \
  --assets 100000000 \
  --strategies <UNIV3_STRATEGY_ADDRESS> \
  --payloads 0x

# or with chain shortcut + alias
node scripts/save-funds/buildVaultInvestCalldata.js \
  --chain arb-one \
  --assets 100000000 \
  --strategies uniV3 \
  --payloads 0x
```

4. Safe: submit the printed `investCalldata` to `SFVault.investIntoStrategy(...)`.

**Safe submission (arb-one only)**

You can pass `--sendToSafe` to propose the transaction directly to the Arbitrum One Safe
`0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F`.

Required env vars:
- `SAFE_PROPOSER_PK`
- `SAFE_RPC_URL` (or `ARBITRUM_MAINNET_RPC_URL`)
- Optional: `SAFE_TX_SERVICE_URL`

**Direct send (arb-sepolia only)**

You can pass `--sendTx` to broadcast the transaction directly on Arbitrum Sepolia.

Required env vars:
- `TESTNET_PK`
- `ARBITRUM_TESTNET_SEPOLIA_RPC_URL`
