// SPDX-License-Identifier: GNU GPLv3
/// @dev This contract is used to be able to test some internal functions

pragma solidity 0.8.28;

import {ParentRewards} from "contracts/helpers/payments/ParentRewards.sol";

contract ParentRewardsHarness is ParentRewards {
    function exposed__parentRewards(
        address initialChildToCheck,
        uint256 contribution,
        uint256 currentReferralReserve,
        uint256 toReferralReserve,
        uint256 currentFee
    ) external returns (uint256, uint256) {
        return
            _parentRewards(
                initialChildToCheck,
                contribution,
                currentReferralReserve,
                toReferralReserve,
                currentFee
            );
    }

    function exposed__referralRewardRatioByLayer(
        int256 layer
    ) external pure returns (uint256 referralRewardRatio) {
        referralRewardRatio = _referralRewardRatioByLayer(layer);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
