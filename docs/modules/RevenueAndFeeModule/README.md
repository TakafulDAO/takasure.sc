# RevenueAndFeeModule

## What this module is for
`RevenueAndFeeModule` is the traffic controller for fee-side cash.

Its job is very small and very specific:

- take a fee that was already identified by the caller
- understand what kind of fee it is from a command byte
- send the referral-reserve portion to `ReferralRewardsModule` when needed
- send the wakala share to `RevShareModule`
- keep the remaining TLD Fund portion inside its own internal buckets

It does not decide referral percentages, parent rewards, or rev-share percentages. Those stay in the modules that already own that logic.

## Main idea
The caller sends one explicit command with the fee amount.

That command tells the module what bucket the money belongs to.

In v1 the routing is code-fixed. That means the module does not store a configurable routing table. The meaning of each command is hardcoded.

This keeps the first version simpler and easier to audit.

## Command map

| Command | Meaning | Current behavior |
| --- | --- | --- |
| `0x00` | Association fee | Send referral reserve to `ReferralRewardsModule`, send 20% of the fee base to `RevShareModule`, keep the rest in the association bucket |
| `0x01` | ALP / benefit fee | Same routing as association fees, but stored in the ALP bucket |
| `0x02` | SaveFunds management fee | Send 20% to `RevShareModule`, keep 80% in the SaveFunds management bucket |
| `0x03` | SaveFunds performance fee | Send 20% to `RevShareModule`, keep 80% in the SaveFunds performance bucket |
| `0x04` | Investment fee | Same routing as SaveFunds, but stored in an investment-fee bucket |
| `0x10` | Crypto-card subscription fee | Reserved, must revert in v1 |
| `0x11` | Crypto-card usage fee | Reserved, must revert in v1 |

Only the lower 6 bits of the command matter in v1. The upper 2 bits are reserved for future use.

## How each current flow fits

### Association fees
The merged `SubscriptionMgmtModule` computes the referral result through `ReferralRewardsModule`, then calls `dispatchFee(...)`.

The money is split like this:

- referral reserve goes to `ReferralRewardsModule`
- 20% of the fee base goes to `RevShareModule`
- the remainder stays inside `RevenueAndFeeModule` as TLD Fund balance for the association bucket

### ALP / benefit fees
There are two expected shapes:

- initial benefit join: includes referral reserve, so it follows the same routing shape as association fees
- recurring benefit payment: no referral reserve, so the whole fee is split 20% wakala and 80% TLD Fund

### SaveFunds fees
`SFVault` calls the module directly for:

- management fees
- performance fees
- future investment fees

In these flows there is no referral reserve. The module only does:

- 20% to `RevShareModule`
- 80% to the matching TLD Fund bucket

## Why the TLD Fund stays inside this module
For this version, the TLD Fund is not a separate contract.

Instead, the module keeps internal balances per command bucket. This gives a clear accounting trail without forcing a second treasury design decision yet.

So the module is both:

- a fee router
- a holding bucket for the TLD Fund side of those fees

## Compatibility path
There is also a temporary `depositRevenue(...)` path for older flows that already know the revenue type and just need a place to park the funds.

This is mainly useful while the protocol is still transitioning from:

- `SubscriptionModule.sol`
- `SubscriptionManagementModule.sol`

toward a merged `SubscriptionMgmtModule`.

This compatibility path is not fee routing. It is only a way to bucket already-classified revenue.

## What stays outside this module

### `ReferralRewardsModule`
Still owns:

- parent lookup
- referral discount logic
- referral reserve sizing
- pending parent reward accounting

### `RevShareModule`
Still owns:

- the split between Takadao and rsNFT holders
- the streaming logic
- the accounting for rev-share claims

### `RevShareNFT`
Still stays as the NFT source for rev-share eligibility.
There is no tranche split in this design.

## Important assumptions

- `SubscriptionMgmtModule` is the future merged module that replaces the current split subscription flow.
- `Savings fees` map to SaveFunds investment-related fees.
- `Investment fees` are not fully wired in the current contracts yet, but they should follow the same routing pattern as SaveFunds fees.
- Crypto-card fees are intentionally not implemented in v1.
- All routed fee movements are expected to use the contribution token / USDC only.

## Open items to settle later

- the exact on-chain destination of the TLD Fund once a treasury contract exists
- the final caller names for benefit modules if ALP is split into more than one contract
- the exact crypto-card sinks once card-provider and card-holder flows are modeled
