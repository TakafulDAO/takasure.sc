// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";

contract CreateDao is Script, GetContractAddress {
    string name = "The LifeDAO";
    bool preJoinEnabled = true;
    bool referralDiscount = true;
    uint256 launchDate = 1739592000; // 2025-02-15 00:00:00 UTC
    uint256 objectiveAmount = 1_000_000 * 10 ** 6; // 100,000,000 USDC

    function run() public {
        address referralGatewayAddress = _getContractAddress(block.chainid, "ReferralGateway");

        ReferralGateway referralGateway = ReferralGateway(referralGatewayAddress);

        vm.startBroadcast();

        referralGateway.createDAO({
            DAOName: name,
            isPreJoinEnabled: preJoinEnabled,
            isReferralDiscountEnabled: referralDiscount,
            launchDate: launchDate,
            objectiveAmount: objectiveAmount
        });

        vm.stopBroadcast();
    }
}
