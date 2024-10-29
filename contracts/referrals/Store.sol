// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

contract Store {
    struct PrepaidMember {
        string tDAOName;
        address member;
        uint256 contributionBeforeFee;
        uint256 contributionAfterFee;
        uint256 finalFee; // Fee after all the discounts and rewards
        uint256 discount;
    }

    PrepaidMember public prepaidMember;

    struct tDAO {
        string name;
        bool preJoinEnabled;
        bool referralDiscount;
        uint40 launchDate; // In seconds. An estimated launch date of the DAO
        address DAOAdmin; // The one that can modify the DAO settings
        address DAOAddress; // To be assigned when the tDAO is deployed
        address rePoolAddress; // To be assigned when the tDAO is deployed
        uint256 objectiveAmount; // In USDC, six decimals
        uint256 currentAmount; // In USDC, six decimals
        uint256 collectedFees; // Fees collected after deduct, discounts, referral reserve and repool amounts. In USDC, six decimals
        uint256 toRepool; // In USDC, six decimals
    }

    tDAO public tdao;
}
