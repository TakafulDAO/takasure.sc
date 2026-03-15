# RevShare Backfill

This folder contains the backfill pipeline used to bootstrap `RevShareModule` from the already deployed `RevShareNFT` holder set.

The flow is:

1. Export the current NFT holders from the subgraph.
2. Build a one-off synthetic revenue allocation using the same accumulator model as `RevShareModule`.
3. Execute the backfill in batches through `adminBackfillRevenue(address[], uint256[])`.

Outputs are intentionally split by chain:

- `scripts/rev-share-backfill/output/mainnet/*`
- `scripts/rev-share-backfill/output/testnet/*`

This avoids mixing Sepolia and Arbitrum One artifacts.

## Contracts That Must Be Deployed

- Deploy `ModuleManager`
- Deploy `RevShareModule`

## Required Onchain Wiring

### AddressManager entries

Before running the live backfill flow, `AddressManager` must contain these entries:

- `PROTOCOL__MODULE_MANAGER`
- `PROTOCOL__CONTRIBUTION_TOKEN`
- `PROTOCOL__REVSHARE_NFT`
- `ADMIN__REVENUE_RECEIVER`
- `MODULE__REVSHARE`

Expected calls:

- `addProtocolAddress("PROTOCOL__MODULE_MANAGER", moduleManager, Protocol)`
- `addProtocolAddress("PROTOCOL__CONTRIBUTION_TOKEN", contributionToken, Protocol)`
- `addProtocolAddress("PROTOCOL__REVSHARE_NFT", revShareNft, Protocol)`
- `addProtocolAddress("ADMIN__REVENUE_RECEIVER", revenueReceiver, Admin)`
- `addProtocolAddress("MODULE__REVSHARE", revShareModule, Module)`

Important note:

- Adding `MODULE__REVSHARE` as a `Module` also registers it inside `ModuleManager`.
- `ModuleManager.addModule(...)` sets the module state to `Enabled` immediately.

### Roles

The backfill execution path needs `OPERATOR`.

- On Arbitrum One, the Safe that eventually executes the proposals is the `OPERATOR` role holder.
- On Arbitrum Sepolia, the signer behind `TESTNET_PK` and `TESTNET_DEPLOYER_ADDRESS` is the `OPERATOR` role holder.

For later Takadao claims, the caller also needs `REVENUE_CLAIMER`.

### RevShareNFT wiring

`RevShareNFT` must point to `AddressManager`:

- `RevShareNFT.setAddressManager(addressManager)`

Without this, the NFT will not call `updateRevenue(...)` on mint/transfer, so live accounting will not stay in sync after the module is deployed.

## Funding Requirement

The backfill execution does not move USDC into the module by itself.

`adminBackfillRevenue(...)` only increases:

- `revenuePerAccount`
- `approvedDeposits`

So the module must be funded with enough USDC to cover the backfill before claims start.

Recommended funding path:

1. Approve USDC to `RevShareModule`
2. Call `depositNoStream(totalBackfillRaw)`

This keeps the accounting clean and emits an explicit event.

## Mainnet Reminders

- Set `ADMIN__REVENUE_RECEIVER` in `AddressManager` before running script `02` in normal mode.
- Set the correct `TOTAL_BACKFILL_TOKENS` in `02-buildRevShareBackfillAllocations.js` before the Arbitrum One run.
- Update `deployments/mainnet_arbitrum_one/ModuleManager.json` after deploying `ModuleManager`.
- Update `deployments/mainnet_arbitrum_one/RevShareModule.json` after deploying `RevShareModule`.

## Environment Checklist

Set the values needed in the `.env` for each chain:

- `MAINNET_SUBGRAPH_URL`
- `TESTNET_SUBGRAPH_URL`
- `ARBITRUM_MAINNET_RPC_URL`
- `ARBITRUM_TESTNET_SEPOLIA_RPC_URL`
- `SAFE_PROPOSER_PK`
- `TESTNET_ACCOUNT`
- `TESTNET_PK`
- `TESTNET_DEPLOYER_ADDRESS`
- `BACKFILL_BATCH_SIZE`
- `BACKFILL_VERIFY_SAMPLE_SIZE`

Notes:

- `BACKFILL_BATCH_SIZE` defaults to `20`.
- `BACKFILL_VERIFY_SAMPLE_SIZE` defaults to `5` and is only used by the Sepolia wrapper script.

## Script Overview

### 01-exportRevSharePioneers.js

Purpose:

- Reads the current RevShare NFT holders from the subgraph.
- Reconstructs per-token ownership timing.
- Writes a chain-specific pioneer snapshot.

Reads:

- `MAINNET_SUBGRAPH_URL` for `--chain arb-one`
- `TESTNET_SUBGRAPH_URL` for `--chain arb-sep`

Writes:

- `output/mainnet/pioneers/revshare_pioneers.json`
- `output/mainnet/pioneers/revshare_pioneers.csv`
- `output/testnet/pioneers/revshare_pioneers.json`
- `output/testnet/pioneers/revshare_pioneers.csv`

Example:

```bash
node scripts/rev-share-backfill/01-exportRevSharePioneers.js --chain arb-one
```

### 02-buildRevShareBackfillAllocations.js

Purpose:

- Reads the export from script `01`.
- Rebuilds the allocation using the same accumulator model as `RevShareModule`.
- Creates the final per-address backfill amounts.

Reads:

- `output/mainnet/pioneers/revshare_pioneers.json`
- `output/testnet/pioneers/revshare_pioneers.json`
- `deployments/<chain>/AddressManager.json`

Writes:

- `output/mainnet/allocations/revshare_backfill_allocations.json`
- `output/mainnet/allocations/revshare_backfill_allocations.csv`
- `output/testnet/allocations/revshare_backfill_allocations.json`
- `output/testnet/allocations/revshare_backfill_allocations.csv`

Behavior:

- Uses the earliest exported `token.mintedAt` as the stream start.
- Uses the current time as the stream end.
- Uses `ADMIN__REVENUE_RECEIVER` from `AddressManager` in normal mode.
- Uses `TESTNET_DEPLOYER_ADDRESS` only when `--test` is enabled.

Examples:

```bash
node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --chain arb-one
node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --chain arb-sep
# Optional fallback only when ADMIN__REVENUE_RECEIVER is not configured yet:
node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --chain arb-sep --test
```

### 03-runRevShareBackfillBatches.js

Purpose:

- Reads the allocations from script `02`.
- Splits them into bounded batches.
- Executes or previews one `adminBackfillRevenue(...)` call per batch.

Reads:

- `output/mainnet/allocations/revshare_backfill_allocations.json`
- `output/testnet/allocations/revshare_backfill_allocations.json`
- `deployments/<chain>/RevShareModule.json`

Writes:

- `output/mainnet/execution/revshare_backfill_execution_report.json`
- `output/testnet/execution/revshare_backfill_execution_report.json`

Behavior by chain:

- `arb-one`: creates one Safe proposal per batch, with sequential Safe nonces
- `arb-sep`: sends each batch directly onchain with `TESTNET_PK`
- `--dry-run`: builds the exact same batches and execution report without creating proposals or sending txs

Example:

```bash
node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js --chain arb-one
node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js --chain arb-sep
node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js --chain arb-one --dry-run
```

## Recommended Execution Order

### Production or testnet live flow

1. Export the current pioneers once the target subgraph is up to date.

```bash
# Arbitrum One
node scripts/rev-share-backfill/01-exportRevSharePioneers.js --chain arb-one

# Arbitrum Sepolia
node scripts/rev-share-backfill/01-exportRevSharePioneers.js --chain arb-sep
```

2. Set the correct `TOTAL_BACKFILL_TOKENS` in `scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js`.

3. Check that `ADMIN__REVENUE_RECEIVER` is already configured in `AddressManager`.

```bash
cast call <ADDRESS_MANAGER> \
  "getProtocolAddressByName(string)((bytes32,address,uint8))" \
  "ADMIN__REVENUE_RECEIVER" \
  --rpc-url <RPC_URL>
```

If it is missing, add it first:

For Arbitrum One, create the transaction in the Safe multisig and execute it once approved.

```bash
source .env

# Arbitrum Sepolia
cast send <ADDRESS_MANAGER> \
  "addProtocolAddress(string,address,uint8)" \
  "ADMIN__REVENUE_RECEIVER" \
  <REVENUE_RECEIVER> \
  0 \
  --rpc-url $ARBITRUM_TESTNET_SEPOLIA_RPC_URL \
  --account $TESTNET_ACCOUNT
```

If it already exists but points to the wrong address, update it:

```bash
source .env

cast send <ADDRESS_MANAGER> \
  "updateProtocolAddress(string,address)" \
  "ADMIN__REVENUE_RECEIVER" \
  <REVENUE_RECEIVER> \
  --rpc-url $ARBITRUM_TESTNET_SEPOLIA_RPC_URL \
  --account $TESTNET_ACCOUNT
```

4. Build the backfill allocations and review the JSON and CSV outputs.

```bash
# Arbitrum One
node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --chain arb-one

# Arbitrum Sepolia
node scripts/rev-share-backfill/02-buildRevShareBackfillAllocations.js --chain arb-sep
```

5. Deploy `ModuleManager`.

```bash
# Arbitrum One
make protocol-deploy-module-manager ARGS="--network arb_one"

# Arbitrum Sepolia
make protocol-deploy-module-manager ARGS="--network arb_sepolia"
```

Update the deployed proxy address into:
- `deployments/<chain>/ModuleManager.json`

6. Deploy `RevShareModule`.

```bash
# Arbitrum One
make modules-deploy-revshare ARGS="--network arb_one"

# Arbitrum Sepolia
make modules-deploy-revshare ARGS="--network arb_sepolia"
```

Update the deployed proxy address into:

- `deployments/<chain>/RevShareModule.json`

7. Add the required `AddressManager` entries.

For Arbitrum One, create the transactions in the Safe multisig and execute them once approved.

For Arbitrum Sepolia, use this rule:

- `PROTOCOL__MODULE_MANAGER`: if missing, add it; if it already exists, update it to the newly deployed `ModuleManager`
- `MODULE__REVSHARE`: if missing, add it after `PROTOCOL__MODULE_MANAGER` is set; if it already exists and you are also replacing `PROTOCOL__MODULE_MANAGER`, delete the old module entry first while the old `ModuleManager` is still active, then add the new `RevShareModule`
- `PROTOCOL__CONTRIBUTION_TOKEN`: if missing, add it using [USDC.json](C:/Users/maike/Desktop/Takadao/Takasure/Contracts/takasure.sc/deployments/testnet_arbitrum_sepolia/USDC.json); if it already exists, leave it unchanged
- `PROTOCOL__REVSHARE_NFT`: if missing, add it using [RevShareNft.json](C:/Users/maike/Desktop/Takadao/Takasure/Contracts/takasure.sc/deployments/testnet_arbitrum_sepolia/RevShareNft.json); if it already exists, leave it unchanged

```bash
source .env

# If MODULE__REVSHARE already exists and you are replacing PROTOCOL__MODULE_MANAGER too,
# remove the old module first while the old ModuleManager is still active.
cast send <ADDRESS_MANAGER> \
  "deleteProtocolAddress(address)" \
  <OLD_REVSHARE_MODULE> \
  --rpc-url $ARBITRUM_TESTNET_SEPOLIA_RPC_URL \
  --account $TESTNET_ACCOUNT

# PROTOCOL__MODULE_MANAGER
# Add if missing, otherwise update to the newly deployed ModuleManager.
cast send <ADDRESS_MANAGER> \
  "addProtocolAddress(string,address,uint8)" \
  "PROTOCOL__MODULE_MANAGER" \
  <MODULE_MANAGER> \
  3 \
  --rpc-url $ARBITRUM_TESTNET_SEPOLIA_RPC_URL \
  --account $TESTNET_ACCOUNT

cast send <ADDRESS_MANAGER> \
  "updateProtocolAddress(string,address)" \
  "PROTOCOL__MODULE_MANAGER" \
  <MODULE_MANAGER> \
  --rpc-url $ARBITRUM_TESTNET_SEPOLIA_RPC_URL \
  --account $TESTNET_ACCOUNT

# PROTOCOL__CONTRIBUTION_TOKEN
# Add if missing using deployments/testnet_arbitrum_sepolia/USDC.json, otherwise leave unchanged.
cast send <ADDRESS_MANAGER> \
  "addProtocolAddress(string,address,uint8)" \
  "PROTOCOL__CONTRIBUTION_TOKEN" \
  <CONTRIBUTION_TOKEN> \
  3 \
  --rpc-url $ARBITRUM_TESTNET_SEPOLIA_RPC_URL \
  --account $TESTNET_ACCOUNT

# PROTOCOL__REVSHARE_NFT
# Add if missing using deployments/testnet_arbitrum_sepolia/RevShareNft.json, otherwise leave unchanged.
cast send <ADDRESS_MANAGER> \
  "addProtocolAddress(string,address,uint8)" \
  "PROTOCOL__REVSHARE_NFT" \
  <REVSHARE_NFT> \
  3 \
  --rpc-url $ARBITRUM_TESTNET_SEPOLIA_RPC_URL \
  --account $TESTNET_ACCOUNT

# MODULE__REVSHARE
# Add after PROTOCOL__MODULE_MANAGER points to the ModuleManager that should own this module.
cast send <ADDRESS_MANAGER> \
  "addProtocolAddress(string,address,uint8)" \
  "MODULE__REVSHARE" \
  <REVSHARE_MODULE> \
  2 \
  --rpc-url $ARBITRUM_TESTNET_SEPOLIA_RPC_URL \
  --account $TESTNET_ACCOUNT
```

8. Ensure `RevShareNFT` points to `AddressManager`.

For Arbitrum One, create the transaction in the Safe multisig and execute it once approved.
```bash
source .env

cast send <REVSHARE_NFT> \
  "setAddressManager(address)" \
  <ADDRESS_MANAGER> \
  --rpc-url $ARBITRUM_TESTNET_SEPOLIA_RPC_URL \
  --account $TESTNET_ACCOUNT
```

9. Fund `RevShareModule` with USDC before any claims are allowed.

Use `totalBackfillRaw` from `output/<scope>/allocations/revshare_backfill_allocations.json` as `<TOTAL_BACKFILL_RAW>`.

For Arbitrum One, create the real-USDC funding transactions in the Safe multisig and execute them once approved.

For Arbitrum Sepolia, use the permissionless USDC-like token already deployed at `deployments/testnet_arbitrum_sepolia/USDC.json`.

```bash
source .env
USDC_LIKE=0xf9b2DE65196fA500527c576De9312E3c626C7d6a
RPC=$ARBITRUM_TESTNET_SEPOLIA_RPC_URL
ACCOUNT=$TESTNET_ACCOUNT
TO=$TESTNET_DEPLOYER_ADDRESS
AMOUNT=<TOTAL_BACKFILL_RAW>

cast send $USDC_LIKE \
  "mintUSDC(address,uint256)" \
  $TO \
  $AMOUNT \
  --rpc-url $RPC \
  --account $ACCOUNT
```

Then approve `RevShareModule` to spend the USDC-like token:

```bash
cast send $USDC_LIKE \
  "approve(address,uint256)" \
  <REVSHARE_MODULE> \
  $AMOUNT \
  --rpc-url $RPC \
  --account $ACCOUNT
```

Deposit without starting a stream:

```bash
cast send <REVSHARE_MODULE> \
  "depositNoStream(uint256)" \
  $AMOUNT \
  --rpc-url $RPC \
  --account $ACCOUNT
```

10. Run the batch executor.

```bash
# Arbitrum One: create Safe proposals, one per batch
node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js --chain arb-one

# Arbitrum Sepolia: send the batches directly onchain with TESTNET_PK
node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js --chain arb-sep

# Preview only, without sending or proposing
node scripts/rev-share-backfill/03-runRevShareBackfillBatches.js --chain arb-one --dry-run
```

11. Verify a sample of backfilled accounts onchain before allowing claims or moving on to `notifyNewRevenue(...)`.

Read the expected `amountRaw` values from:

- `scripts/rev-share-backfill/output/<chain>/allocations/revshare_backfill_allocations.json`

For each sampled address, compare the JSON `amountRaw` against `revenuePerAccount(address)` on `RevShareModule`.

Manual `cast` command:

```bash
cast call <REVSHARE_MODULE> \
  "revenuePerAccount(address)(uint256)" \
  <ACCOUNT> \
  --rpc-url <RPC_URL>
```

What to check:

- `<ACCOUNT>` must exist in the matching `revshare_backfill_allocations.json`
- the returned value must equal that address's `amountRaw`
- do this before claims change `revenuePerAccount(address)`

Example:

```bash
# Compare against scripts/rev-share-backfill/output/mainnet/allocations/revshare_backfill_allocations.json
cast call <REVSHARE_MODULE> \
  "revenuePerAccount(address)(uint256)" \
  0x1234...abcd \
  --rpc-url $ARBITRUM_MAINNET_RPC_URL
```

### If you are rehearsing on Arbitrum Sepolia

Run:

```bash
bash scripts/rev-share-backfill/run_arb_sepolia_backfill.sh
```

The script loads `.env`, redeploys `ModuleManager` and `RevShareModule`, rewrites their Sepolia deployment JSON files, updates the module-related `AddressManager` entries to the new deployments, only creates the Sepolia contribution-token / RevShare-NFT entries if they are missing, and finally verifies the first `BACKFILL_VERIFY_SAMPLE_SIZE` pioneer allocations onchain against `revenuePerAccount(address)`.

## Contract Calls Used In This Flow

These are the important onchain calls around the pipeline:

- `AddressManager.addProtocolAddress("PROTOCOL__MODULE_MANAGER", ...)`
- `AddressManager.addProtocolAddress("PROTOCOL__CONTRIBUTION_TOKEN", ...)`
- `AddressManager.addProtocolAddress("PROTOCOL__REVSHARE_NFT", ...)`
- `AddressManager.addProtocolAddress("ADMIN__REVENUE_RECEIVER", ...)`
- `AddressManager.addProtocolAddress("MODULE__REVSHARE", ...)`
- `RevShareNFT.setAddressManager(addressManager)`
- `RevShareModule.depositNoStream(totalBackfillRaw)`
- `RevShareModule.adminBackfillRevenue(address[], uint256[])`

Optional operational calls after go-live:

- `RevShareModule.setAvailableDate(...)`
- `RevShareModule.setRewardsDuration(...)`
- `RevShareModule.notifyNewRevenue(...)`
