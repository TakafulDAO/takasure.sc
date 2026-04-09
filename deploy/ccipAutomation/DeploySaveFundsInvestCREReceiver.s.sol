// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {SaveFundsInvestCREReceiver} from "contracts/helpers/chainlink/automation/SaveFundsInvestCREReceiver.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ProtocolAddress} from "contracts/types/Managers.sol";

contract DeploySaveFundsInvestCREReceiver is Script, GetContractAddress {
    string internal constant CRE_FORWARDER_NAME = "EXTERNAL__CL_CRE_FORWARDER";
    string internal constant SAVE_FUNDS_RUNNER_NAME = "HELPER__SF_INVEST_RUNNER";
    string internal constant CRE_WORKFLOW_OWNER_NAME = "ADMIN__CRE_WORKFLOW_OWNER";

    function run() external returns (SaveFundsInvestCREReceiver receiver) {
        require(block.chainid == ARB_MAINNET_CHAIN_ID, "Run only on Arbitrum One mainnet");

        AddressManager addressManager = AddressManager(_getContractAddress(block.chainid, "AddressManager"));
        address runnerProxy = _getContractAddress(block.chainid, "SaveFundsInvestAutomationRunner");

        console2.log("Deploying SaveFundsInvestCREReceiver...");

        vm.startBroadcast();
        receiver = new SaveFundsInvestCREReceiver(addressManager);
        vm.stopBroadcast();

        console2.log("SaveFundsInvestCREReceiver deployed at:");
        console2.logAddress(address(receiver));
        _logRunnerConfiguration(addressManager, runnerProxy);
        _logOptionalConfiguredAddress(addressManager, CRE_FORWARDER_NAME, "Configured CRE forwarder");
        _logOptionalConfiguredAddress(addressManager, CRE_WORKFLOW_OWNER_NAME, "Configured CRE workflow owner");

        return receiver;
    }

    function _logOptionalConfiguredAddress(AddressManager addressManager, string memory name, string memory label)
        internal
        view
    {
        try addressManager.getProtocolAddressByName(name) returns (ProtocolAddress memory protocolAddress) {
            console2.log(label);
            console2.logAddress(protocolAddress.addr);
        } catch {
            console2.log(name);
            console2.log("is not configured yet in AddressManager.");
        }
    }

    function _logRunnerConfiguration(AddressManager addressManager, address expectedRunner) internal view {
        try addressManager.getProtocolAddressByName(SAVE_FUNDS_RUNNER_NAME) returns (ProtocolAddress memory protocolAddress) {
            require(
                protocolAddress.addr == expectedRunner, string.concat(SAVE_FUNDS_RUNNER_NAME, " is not configured as expected")
            );
            require(
                addressManager.hasRole(Roles.KEEPER, protocolAddress.addr),
                "SaveFundsInvestAutomationRunner must remain KEEPER"
            );
            console2.log("Configured runner:");
            console2.logAddress(protocolAddress.addr);
            return;
        } catch {
            console2.log(SAVE_FUNDS_RUNNER_NAME);
            console2.log("is not configured yet in AddressManager.");
            console2.log("Configure it before activating the CRE workflow.");
        }
    }
}
