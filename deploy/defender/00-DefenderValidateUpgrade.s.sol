// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {Defender, Options, ApprovalProcessResponse} from "openzeppelin-foundry-upgrades/Defender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract DefenderValidateUpgrade is Script {
    function run() external {
        // ApprovalProcessResponse memory approvalProcess = Defender.getDeployApprovalProcess();
        // console2.log("Approval process id", approvalProcess.approvalProcessId);
        // console2.log("Approval process via", approvalProcess.viaType);
        // string memory relayerKey = "RELAYER_ID";

        // bytes32 salt = keccak256(abi.encodePacked(block.timestamp, msg.sender));

        Options memory opts;
        // opts.defender.salt = salt;
        // opts.defender.useDefenderDeploy = true;
        // opts.defender.relayerId = vm.envString(relayerKey);
        // opts.defender.upgradeApprovalProcessId = approvalProcess.approvalProcessId;

        Upgrades.validateUpgrade("PrejoinModule.sol", opts);

        console2.log("PrejoinModule.sol is upgradeable");
    }
}
