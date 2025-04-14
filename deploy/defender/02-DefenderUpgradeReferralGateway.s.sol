// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {ProposeUpgradeResponse, Defender, Options, ApprovalProcessResponse} from "openzeppelin-foundry-upgrades/Defender.sol";

contract DefenderUpgradeReferralGateway is Script, GetContractAddress {
    function run() external {
        address referralGatewayAddress = _getContractAddress(block.chainid, "ReferralGateway");
        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, msg.sender));

        ApprovalProcessResponse memory approvalProcess = Defender.getUpgradeApprovalProcess();
        console2.log("Approval process id", approvalProcess.approvalProcessId);
        console2.log("Approval process via", approvalProcess.viaType);
        string memory relayerKey = "RELAYER_ID";

        Options memory opts;
        opts.defender.skipLicenseType = true;
        opts.referenceContract = "ReferralGatewayV1.sol";

        opts.defender.salt = salt;
        opts.defender.useDefenderDeploy = true;
        opts.defender.relayerId = vm.envString(relayerKey);
        opts.defender.upgradeApprovalProcessId = approvalProcess.approvalProcessId;

        ProposeUpgradeResponse memory response = Defender.proposeUpgrade(
            referralGatewayAddress,
            "ReferralGateway.sol",
            opts
        );

        console2.log("Proposal id", response.proposalId);
        console2.log("Url", response.url);
    }
}
