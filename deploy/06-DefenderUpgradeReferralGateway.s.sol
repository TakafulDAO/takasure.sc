// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {ProposeUpgradeResponse, Defender, Options} from "openzeppelin-foundry-upgrades/src/Defender.sol";

contract DefenderUpgradeReferralGateway is Script, GetContractAddress {
    function run() external {
        address referralGatewayAddress = _getContractAddress(block.chainid, "ReferralGateway");
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, msg.sender));

        Options memory opts;
        opts.defender.skipLicenseType = true;
        opts.defender.salt = salt;

        ProposeUpgradeResponse memory response = Defender.proposeUpgrade(
            referralGatewayAddress,
            "ReferralGateway.sol",
            opts
        );

        console2.log("Proposal id", response.proposalId);
        console2.log("Url", response.url);
    }
}
