# Save Funds Scripts

This folder contains helper scripts to build calldata and optionally:
- simulate in Tenderly,
- propose to Safe (arb-one),
- broadcast onchain (arb-sepolia).

All command examples in this README assume `bash`/`zsh`.

## `.env` setup

Add these variables to the repo root `.env`:

```dotenv
# -------- Required for arb-one reads --------
ARBITRUM_MAINNET_RPC_URL=
# Optional alias used by some scripts for arb-one RPC
SAFE_RPC_URL=

# -------- Required for --simulateTenderly --------
TENDERLY_ACCESS_KEY=
TENDERLY_ACCOUNT_SLUG=
TENDERLY_PROJECT_SLUG=

# -------- Required only for --sendToSafe (arb-one) --------
SAFE_PROPOSER_PK=
SAFE_TX_SERVICE_URL=https://safe-transaction-arbitrum.safe.global/api/v1

# -------- Required only for --discordNotification --------
DISCORD_WEBHOOK_URL=
# Optional override for the webhook display name
DISCORD_WEBHOOK_USERNAME=

# -------- Required only for --sendTx (arb-sepolia) --------
TESTNET_PK=
ARBITRUM_TESTNET_SEPOLIA_RPC_URL=
```

### Where to find Tenderly values

Use Tenderly dashboard `Settings` > `Integration`:
- `TENDERLY_ACCESS_KEY`: API access key.
- `TENDERLY_ACCOUNT_SLUG`: workspace/account slug.
- `TENDERLY_PROJECT_SLUG`: project slug.

## Read current pool state

```bash
source .env
POOL=0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6
cast call --rpc-url $ARBITRUM_MAINNET_RPC_URL $POOL "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)"
```

`slot0()` returns:
- `sqrtPriceX96`
- `tick`
- `observationIndex`
- `observationCardinality`
- `observationCardinalityNext`
- `feeProtocol`
- `unlocked`

## Global behavior (shared)

These scripts share the same execution pattern:
1. Build calldata only (default behavior).
2. Add `--simulateTenderly` to run simulation first.
3. Add `--sendToSafe` (arb-one) to propose transaction to Safe.
4. Or add `--sendTx` (arb-sepolia) to broadcast directly.

When `--discordNotification` is used on the rebalance builder:
- the script auto-runs Tenderly if you did not pass `--simulateTenderly`,
- reuses that same simulation for the signer summary,
- proposes to Safe first when `--sendToSafe` is present,
- then sends exactly one Discord message after the Safe proposal succeeds.

Recommended safe flow:
1. Run with `--simulateTenderly`.
2. Confirm `tenderlyStatus: ok` and inspect `tenderlyDashboardUrl`.
3. Re-run the same command adding `--sendToSafe` when you want execution.

## Common params (shared)

These are shared across:
- `buildVaultInvestCalldata.js`
- `buildAggregatorRebalanceCalldata.js`
- `buildAggregatorHarvestCalldata.js`

### Common execution params

- `--help`  
  Show usage.

- `--chain <arb-one|arb-sepolia>`  
  Select chain config / deployment defaults.

- `--strategies <a,b>`  
  Comma-separated strategy addresses. `uniV3` alias is supported when chain context is available.

- `--payloads <p1,p2>`  
  Pre-encoded per-strategy payloads. Length must match `--strategies`.

- `--simulateTenderly`  
  Simulate transaction in Tenderly (arb-one only).

- `--discordNotification`  
  Send a signer-friendly Discord summary after simulation / Safe proposal.  
  Current v1 scope: `buildAggregatorRebalanceCalldata.js` only, `arb-one` only, single `uniV3` rebalance bundle only.

- `--discorNotification`  
  Deprecated alias for `--discordNotification`.

- `--tenderlyGas <uint>`  
  Override simulation gas limit.

- `--tenderlyBlock <uint|latest>`  
  Override simulation block.

- `--tenderlySimulationType <str>`  
  Optional simulation type.

- `--sendToSafe`  
  Propose transaction to Arbitrum One Safe (`--chain arb-one` required).

- `--sendTx`  
  Broadcast on Arbitrum Sepolia (`--chain arb-sepolia` required).

### Common action/swap params

Used in action-data mode (supported by invest/rebalance/harvest builders):

- `--otherRatioBps <bps>`  
  Target other-token ratio (0..10000).  
  Note: invest also supports `auto` (see invest section).

- `--pmDeadline <uint>`  
  Position manager deadline (`0` is sentinel in new encoding flows).

- `--minUnderlying <uint>`  
  Minimum underlying out for PM actions.

- `--minOther <uint>`  
  Minimum other-token out for PM actions.

- `--swapToOtherData <0x>`  
  Raw encoded underlying -> other swap data.

- `--swapToOtherTokenIn <addr>`
- `--swapToOtherTokenOut <addr>`
- `--swapToOtherFee <fee>`
- `--swapToOtherBps <bps>`
- `--swapToOtherAmountIn <uint>`
- `--swapToOtherAmountOutMin <uint>`
- `--swapToOtherDeadline <uint>`
- `--swapToOtherRecipient <addr>`

- `--swapToUnderlyingData <0x>`  
  Raw encoded other -> underlying swap data.

- `--swapToUnderlyingTokenIn <addr>`
- `--swapToUnderlyingTokenOut <addr>`
- `--swapToUnderlyingFee <fee>`
- `--swapToUnderlyingBps <bps>`
- `--swapToUnderlyingAmountIn <uint>`
- `--swapToUnderlyingAmountOutMin <uint>`
- `--swapToUnderlyingDeadline <uint>`
- `--swapToUnderlyingRecipient <addr>`

## `SFVault::investIntoStrategy`

Script: `scripts/save-funds/automation/buildVaultInvestCalldata.js`  
Builds calldata for:
`SFVault.investIntoStrategy(uint256 assets, address[] strategies, bytes[] payloads)`.

### Script-specific params

- `--assets <uint|full|max|all>`  
  Amount of underlying to invest.  
  `full|max|all` reads `SFVault.idleAssets()`.

- `--defaultSwapFee <fee>`  
  Default fee used by swap builders when per-swap fee is omitted.

- `--otherRatioBps <bps|auto>`  
  Invest supports `auto` (LP-target ratio estimation).

### Example: simulate invest full vault balance

```bash
node scripts/save-funds/automation/buildVaultInvestCalldata.js \
  --chain arb-one \
  --assets full \
  --strategies uniV3 \
  --otherRatioBps auto \
  --swapToOtherFee 100 \
  --swapToOtherBps 10000 \
  --swapToUnderlyingFee 100 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline $(( $(date +%s) + 1800 )) \
  --simulateTenderly
```

> [!TIP]
> USDC uses 6 decimals (`100 USDC = 100000000`).

## `SFStrategyAggregator::rebalance`

Script: `scripts/save-funds/automation/buildAggregatorRebalanceCalldata.js`  
Builds calldata for:
`SFStrategyAggregator.rebalance(bytes data)`.

### Modes

- raw mode: `--data <0x>`
- bundle mode: `--strategies` + optional `--payloads`
- builder mode: `--tickLower` + `--tickUpper` (+ optional action-data / swap params)

### Script-specific params

- `--data <0x>`  
  Raw ABI-encoded rebalance bundle.

- `--discordNotification`  
  Send a Discord signer summary for the simulated/proposed rebalance.  
  v1 guardrails:
  - only `--chain arb-one`
  - only a single resolved `SFUniswapV3Strategy`
  - no support for raw `--data 0x` / multi-strategy bundle notifications
  - requires `DISCORD_WEBHOOK_URL`

- `--otherRatioBps <bps|auto>`  
  Rebalance supports `auto`, which estimates the LP-target ratio for the target tick range using the live spot price first.

- `--tickLower <int>`  
  New lower tick (builder mode).

- `--tickUpper <int>`  
  New upper tick (builder mode).

- `--actionData <0x>`  
  Raw actionData for new encoding, overrides action builder fields.

### Rebalance examples

1. Rebalance only updating ticks

```bash
node scripts/save-funds/automation/buildAggregatorRebalanceCalldata.js \
  --chain arb-one \
  --strategies uniV3 \
  --tickLower -594 \
  --tickUpper 606 \
  --pmDeadline $(( $(date +%s) + 1800 )) \
  --simulateTenderly
```

2. Out of position (current tick is outside range, either `< lower` or `> upper`): rebalance and redeploy available liquidity

```bash
node scripts/save-funds/automation/buildAggregatorRebalanceCalldata.js \
  --chain arb-one \
  --strategies uniV3 \
  --tickLower <new_lower_tick> \
  --tickUpper <new_upper_tick> \
  --otherRatioBps auto \
  --swapToOtherFee 100 \
  --swapToOtherBps 10000 \
  --swapToUnderlyingFee 100 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline $(( $(date +%s) + 1800 )) \
  --simulateTenderly \
  --discordNotification
```

3. Rebalance all active sub-strategies with empty payloads

```bash
node scripts/save-funds/automation/buildAggregatorRebalanceCalldata.js \
  --chain arb-one \
  --data 0x \
  --simulateTenderly
```

4. Rebalance, propose to Safe, and send a Discord signer summary

```bash
node scripts/save-funds/automation/buildAggregatorRebalanceCalldata.js \
  --chain arb-one \
  --strategies uniV3 \
  --tickLower -594 \
  --tickUpper 606 \
  --otherRatioBps auto \
  --swapToOtherFee 100 \
  --swapToOtherBps 10000 \
  --swapToUnderlyingFee 100 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline 0 \
  --sendToSafe \
  --discordNotification
```

Expected simulation output includes:
- `tenderlySimulationId`
- `tenderlyDashboardUrl`
- `tenderlyStatus: ok`

Expected Discord summary fields include:
- current position (`USDC` + `USDT`)
- swap cost
- new tick lower / upper
- new position (`USDC` + `USDT`)
- remainings (`USDC` swept to vault / `USDT` left in strategy)
- deadline in Riyadh time
- Safe queue / tx-service links when `--sendToSafe` is used
- Uniswap position link from the simulated token ID, with the note that it only becomes usable after signing and can change if the transaction is rebuilt

> [!TIP]
> Swap-builder mode supports a single strategy only.

> [!TIP]
> To maximize deployment after rebalance, choose a range that contains the current tick.

> [!TIP]
> Prefer `--otherRatioBps auto` for rebalance. It uses the same spot-price-first LP-target ratio estimation as the invest builder and is more precise than a fixed `5000` guess for asymmetric ranges.

### Safe leftovers process (after rebalance)

If leftovers remain:
1. Harvest with full `USDT -> USDC` swap (sweep proceeds to vault as underlying).
2. Re-invest vault `full` underlying with `auto` ratio.

1) Sweep leftovers to vault via harvest:

```bash
node scripts/save-funds/automation/buildAggregatorHarvestCalldata.js \
  --chain arb-one \
  --strategies uniV3 \
  --swapToOtherData 0x \
  --swapToUnderlyingFee 100 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline $(( $(date +%s) + 1800 )) \
  --simulateTenderly
```

2) Re-invest everything from vault:

```bash
node scripts/save-funds/automation/buildVaultInvestCalldata.js \
  --chain arb-one \
  --assets full \
  --strategies uniV3 \
  --otherRatioBps auto \
  --swapToOtherFee 100 \
  --swapToOtherBps 10000 \
  --swapToUnderlyingFee 100 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline $(( $(date +%s) + 1800 )) \
  --simulateTenderly
```

After simulations are good, rerun each with `--sendToSafe` to execute.

## `SFStrategyAggregator::harvest`

Script: `scripts/save-funds/automation/buildAggregatorHarvestCalldata.js`  
Builds calldata for:
`SFStrategyAggregator.harvest(bytes data)`.

### Modes

- raw mode: `--data <0x>`
- bundle mode: `--strategies` + optional `--payloads`
- action-data mode: ratio + optional swap builder data

### Script-specific params

- `--data <0x>`  
  Raw ABI-encoded harvest bundle.

### Harvest examples

1. Harvest all active sub-strategies (empty bundle payload)

```bash
node scripts/save-funds/automation/buildAggregatorHarvestCalldata.js \
  --chain arb-one \
  --data 0x \
  --simulateTenderly
```

2. Harvest one strategy with empty payload

```bash
node scripts/save-funds/automation/buildAggregatorHarvestCalldata.js \
  --chain arb-one \
  --strategies uniV3 \
  --simulateTenderly
```

3. Harvest with action-data swap builders

```bash
node scripts/save-funds/automation/buildAggregatorHarvestCalldata.js \
  --chain arb-one \
  --strategies uniV3 \
  --otherRatioBps 5000 \
  --swapToOtherFee 100 \
  --swapToOtherBps 10000 \
  --swapToUnderlyingFee 100 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline $(( $(date +%s) + 1800 )) \
  --simulateTenderly
```

4. Harvest and swap all received USDT -> USDC before sweep

```bash
node scripts/save-funds/automation/buildAggregatorHarvestCalldata.js \
  --chain arb-one \
  --strategies uniV3 \
  --swapToOtherData 0x \
  --swapToUnderlyingFee 100 \
  --swapToUnderlyingBps 10000 \
  --pmDeadline $(( $(date +%s) + 1800 )) \
  --simulateTenderly
```

Expected simulation output includes:
- `tenderlySimulationId`
- `tenderlyDashboardUrl`
- `tenderlyStatus: ok`

> [!TIP]
> `--data 0x` means aggregator harvests all active child strategies with empty payloads.

> [!TIP]
> Swap-builder mode supports a single strategy only.
