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

        _requireConfiguredAddress(addressManager, SAVE_FUNDS_RUNNER_NAME, runnerProxy);
        console2.log("Deploying SaveFundsInvestCREReceiver...");

        require(addressManager.hasRole(Roles.KEEPER, runnerProxy), "SaveFundsInvestAutomationRunner must remain KEEPER");

        vm.startBroadcast();
        receiver = new SaveFundsInvestCREReceiver(addressManager);
        vm.stopBroadcast();

        console2.log("SaveFundsInvestCREReceiver deployed at:");
        console2.logAddress(address(receiver));
        console2.log("Configured runner:");
        console2.logAddress(runnerProxy);
        _logOptionalConfiguredAddress(addressManager, CRE_FORWARDER_NAME, "Configured CRE forwarder");
        _logOptionalConfiguredAddress(addressManager, CRE_WORKFLOW_OWNER_NAME, "Configured CRE workflow owner");

        return receiver;
    }

    function _requireConfiguredAddress(AddressManager addressManager, string memory name, address expectedAddr)
        internal
        view
    {
        ProtocolAddress memory protocolAddress = addressManager.getProtocolAddressByName(name);
        require(protocolAddress.addr == expectedAddr, string.concat(name, " is not configured as expected"));
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
}
