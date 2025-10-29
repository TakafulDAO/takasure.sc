# Changelog

This file tracks changes since **08/24/2025**.

-   ![status](https://img.shields.io/badge/status-unreleased-orange) → Features deployed only to **testnet**
    -   It will include the description of the changes and the new function signatures (if any).
-   ![status](https://img.shields.io/badge/status-released-brightgreen) → Features deployed to **mainnet**
    -   It will include the description of the changes and will reference the testnet deployment date for more details.

---

## 24 August 2025

### [Testnet] ![status](https://img.shields.io/badge/status-unreleased-orange)

#### Changed

-   Deployment of invite-only feature. This includes a new flag to enable/disable the rewards system independently of the discounts system.
-   Updated `getDAOData` function to include a new `rewardsEnabled` flag.  
    **New signature:**

```solidity
function getDAOData()
    external
    view
    returns (
        bool preJoinDiscountEnabled,
        bool referralDiscountEnabled,
        bool rewardsEnabled,
        address DAOAdmin,
        address DAOAddress,
        uint256 launchDate,
        uint256 objectiveAmount,
        uint256 currentAmount,
        uint256 collectedFees,
        address rePoolAddress,
        uint256 toRepool,
        uint256 referralReserve
    );
```

[Back to top](#changelog)

---

## 27 August 2025

### ![status](https://img.shields.io/badge/status-released-brightgreen)

#### Changed

-   Deployment of invite-only feature
-   Related testnet changes from [24 August 2025](#24-august-2025)

[Back to top](#changelog)

---

## 12 September 2025

### [Testnet] ![status](https://img.shields.io/badge/status-unreleased-orange)

#### Changed

-   Updated `getPrepaidMember` function to include a new `isDonated` flag.  
    **New signature:**

```solidity
function getPrepaidMember(
        address member
    )
        external
        view
        returns (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 feeToOperator,
            uint256 discount,
            bool isDonated
        );
```

[Back to top](#changelog)

---

## 22 September 2025

### ![status](https://img.shields.io/badge/status-released-brightgreen)

#### Changed

-   Deployment with related testnet changes from [12 September 2025](#12-september-2025)

[Back to top](#changelog)

---

## 28 October 2025

### [Testnet] ![status](https://img.shields.io/badge/status-unreleased-orange)

#### Changed

-   New function added so users can opt to pay a prorated contribution if previously they donated

```solidity
    function payContributionAfterWaive(
        uint256 newContribution,
        address prepaidMember,
        uint256 couponAmount,
        uint256 associationTimestamp,
        uint256 benefitTimestamp
    )
        external
        returns (uint256 finalFee, uint256 discount);
```

Where:

-   newContribution Will be the corresponding amount for the new plan. (Not the amount to transfer) In USDC six decimals
-   prepaidMember The address of the prepaid member
-   couponAmount The amount of the coupon. In USDC six decimals
-   associationTimestamp The timestamp the first payment was made

This function will reward the same parent (if any)
