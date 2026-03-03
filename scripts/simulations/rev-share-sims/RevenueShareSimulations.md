# RevShare Month Simulation → CSV (Foundry)

-   [RevShare Month Simulation → CSV (Foundry)](#revshare-month-simulation--csv-foundry)
    -   [How to run](#how-to-run)
    -   [Where to find the output](#where-to-find-the-output)
    -   [What the script simulates](#what-the-script-simulates)
    -   [Logged columns:](#logged-columns)
    -   [Variables you can tweak in the script](#variables-you-can-tweak-in-the-script)

## How to run

Use the command

```bash
make simulate-rev-share-distribution
```

This calls the script RevShareMonthSimToCsv.s.sol and writes the CSV—no --broadcast required.

## Where to find the output

The CSV is written to: `scripts/simulations/revshare_sim.csv` If the file doesn’t exist, the script creates it automatically.

## What the script simulates

-   Mints rsNFT to 10 users (Alice → Judy) with different NFT counts.
-   Rewards window set to 30 days (rev.setRewardsDuration(30 days)).
-   Daily deposits for 30 days, one per day, pseudo-random but bounded:
    -   Amounts between 500 USDC and 1000 USDC in 100 USDC steps (i.e., 500, 600, …, 1000; token has 6 decimals).
-   Every user claims at least once every two days.
-   Takadao (via REVENUE_CLAIMER) also claims every two days.

## Logged columns:

One row per event:

```sql
day, timestamp, action, actor, amount,
rewardRatePioneersScaled, rewardRateTakadaoScaled,
periodFinish, revenuePerNftOwnedByPioneers, takadaoRevenueScaled,
totalSupply, balanceOfActor, earnedViewBefore, approvedDeposits
```

action ∈ {MINT, DEPOSIT, CLAIM, TAKADAO_CLAIM}
Amounts are integers in USDC’s 6 decimals.

## Variables you can tweak in the script

Edit the constants at the top of RevShareMonthSimToCsv.s.sol:

```solidity
// File output location
string  constant OUT      = "scripts/simulations/revshare_sim.csv";

// Simulation horizon
uint256 constant SIM_DAYS = 30;

// Time step granularity (usually leave as 1 day)
uint256 constant ONE_DAY  = 1 days;

// Daily deposit bounds (USDC has 6 decimals)
uint256 constant DEP_MIN  = 500e6;   // lower bound
uint256 constant DEP_MAX  = 1000e6;  // upper bound
uint256 constant DEP_STEP = 100e6;   // step size
```

To change the rewards window, adjust this line in run():

```solidity
rev.setRewardsDuration(30 days);
```

(e.g., 7 days, 90 days). This doesn’t alter core logic—just the window length.

CSV write permissions: ensure your foundry.toml includes:

Import into Excel/Sheets normally (comma-separated). If you need human-readable USDC, divide amounts by 1e6 in your sheet.
