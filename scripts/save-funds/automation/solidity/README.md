# Save Funds Solidity Automation

This folder contains Solidity-based automation for Save Funds.

## SaveFundsInvestAutomationRunner

Contract:
- `scripts/save-funds/automation/solidity/SaveFundsInvestAutomationRunner.sol`

### What it does

- Implements a Chainlink-compatible upkeep runner for vault investments.
- Reads all vault idle assets from `SFVault.idleAssets()`.
- Builds a UniV3 strategy payload on-chain (same intent as `buildVaultInvestCalldata.js`).
- Calls `SFVault.investIntoStrategy(...)` using full idle assets.

### Core behavior

- Time-gated by `interval` and `lastRun`.
- Defaults:
- `interval = 24 hours`
- `skipIfPaused = true`
- `strictUniOnlyAllocation = true`
- `useAutoOtherRatio = true`
- `testMode = false`
- `checkUpkeep` returns false when paused, interval not reached, dependencies paused (if enabled), allocation check fails (if enabled), or idle assets are below `minIdleAssets`.
- `performUpkeep` emits attempt/success/failure/skip events and updates `lastRun` on execution paths.

### Interval and test mode

- In normal mode, `setInterval(newIntervalSeconds)` requires `newIntervalSeconds >= 24 hours`.
- In test mode (`toggleTestMode()` enabled), `setInterval` can use lower values (`> 0`).

## Deployment

The deploy script resolves addresses from `deployments/<network>/` using `GetContractAddress`:
- `SFVault`
- `SFStrategyAggregator`
- `SFUniswapV3Strategy`
- `AddressManager`

### Make target

```bash
make deploy-chainlink-invest-upkeep ARGS="--network arb_sepolia"
```

```bash
make deploy-chainlink-invest-upkeep ARGS="--network arb_one"
```

`Makefile` target:
- `deploy-chainlink-invest-upkeep` -> `DeploySaveFundsInvestAutomationRunner`

## Post-deploy on-chain setup

Set environment variables first:

```bash
RPC_URL=<rpc-url>
RUNNER=<deployed-runner-address>
ADDRESS_MANAGER=<AddressManager-address>
```

### 1) Grant KEEPER role to runner in the multisig

The runner must hold `KEEPER` so vault investment execution is authorized.

```bash
KEEPER_ROLE=$(cast keccak "KEEPER")
echo $KEEPER_ROLE
```

Call in the operator multisig

`AddressManager.proposeRoleHolder(KEEPER_ROLE, RUNNER)`

```
cast send $RUNNER "acceptKeeperRole()" --rpc-url $RPC_URL --account <account>
cast call $ADDRESS_MANAGER "hasRole(bytes32,address)(bool)" $KEEPER_ROLE $RUNNER --rpc-url $RPC_URL
```

### 2) Configure runner parameters (owner only)

```bash
cast send $RUNNER "setLastRun(uint256)" <timestamp> --rpc-url $RPC_URL --account <account>
cast send $RUNNER "toggleTestMode()" --rpc-url $RPC_URL --account <account>
cast send $RUNNER "setInterval(uint256)" 3600 --rpc-url $RPC_URL --account <account>
```

### 3) Chainlink Automation settings

Create a new upkeep with:
- Type: `Custom logic`
- Target contract: `RUNNER`
- `checkData`: `0x`
- Gas limit: set high enough for `performUpkeep` path (use a conservative limit, e.g. `2,000,000+`, then tune with production traces)
- Funding: add LINK balance for upkeep execution

The cadence is enforced by contract state (`interval`), not by a Chainlink cron schedule.

### 4) Live verification

Waiy or call `checkUpkeep` to return true, then call `performUpkeep` to execute an investment cycle.

```bash
cast call $RUNNER "checkUpkeep(bytes)(bool,bytes)" 0x --rpc-url $RPC_URL
cast send $RUNNER "performUpkeep(bytes)" 0x --rpc-url $RPC_URL --account <account>
```

### 5) After tests

```bash
cast send $RUNNER "setLastRun(uint256)" <timestamp> --rpc-url $RPC_URL --account <account>
cast send $RUNNER "toggleTestMode()" --rpc-url $RPC_URL --account <account>
cast send $RUNNER "setInterval(uint256)" 86400 --rpc-url $RPC_URL --account <account>
cast send $RUNNER "transferOwnership(address)" <newOwner> --rpc-url $RPC_URL --account <account>
```

Then from `<newOwner>` call:

`Runner.acceptOwnership()`

## Tests

```bash
forge test --match-contract SaveFundsInvestAutomationRunnerForkTest -vv
```
