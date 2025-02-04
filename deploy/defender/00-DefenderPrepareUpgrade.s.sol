// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {Defender, Options, ApprovalProcessResponse} from "openzeppelin-foundry-upgrades/Defender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DefenderPrepareUpgrade is Script {
    function run() external {
        ApprovalProcessResponse memory approvalProcess = Defender.getDeployApprovalProcess();
        console2.log("Approval process id", approvalProcess.approvalProcessId);
        console2.log("Approval process via", approvalProcess.viaType);
        string memory relayerKey = "RELAYER_ID";

        bytes32 salt = keccak256(abi.encodePacked(block.timestamp, msg.sender));

        Options memory opts;
        opts.defender.salt = salt;
        opts.defender.useDefenderDeploy = true;
        opts.defender.relayerId = vm.envString(relayerKey);
        opts.defender.upgradeApprovalProcessId = approvalProcess.approvalProcessId;

        Upgrades.prepareUpgrade("ReferralGateway.sol", opts);
    }
}
