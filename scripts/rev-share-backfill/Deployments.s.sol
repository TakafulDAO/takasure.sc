// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";

contract Deployments is Script {
    address constant NFT = 0x931eD799F48AaE6908F8Fe204712972f4a64c941;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant REVENUE_RECEIVER = 0xa0Ee7A142d267C1f36714E4a8F75612F20a79720; // Last account in Anvil

    function run() external returns (address addressManager, address moduleManager, address revShareModule) {
        vm.startBroadcast(msg.sender);

        addressManager =
            Upgrades.deployUUPSProxy("AddressManager.sol", abi.encodeCall(AddressManager.initialize, (msg.sender)));

        moduleManager =
            Upgrades.deployUUPSProxy("ModuleManager.sol", abi.encodeCall(ModuleManager.initialize, (addressManager)));

        revShareModule = Upgrades.deployUUPSProxy(
            "RevShareModule.sol", abi.encodeCall(RevShareModule.initialize, (addressManager, "REVENUE_SHARE_MODULE"))
        );

        AddressManager(addressManager).addProtocolAddress("MODULE_MANAGER", moduleManager, ProtocolAddressType.Protocol);

        AddressManager(addressManager)
            .addProtocolAddress("REVENUE_SHARE_MODULE", revShareModule, ProtocolAddressType.Protocol);

        AddressManager(addressManager).addProtocolAddress("REVSHARE_NFT", NFT, ProtocolAddressType.Protocol);

        AddressManager(addressManager).addProtocolAddress("CONTRIBUTION_TOKEN", USDC, ProtocolAddressType.Protocol);

        AddressManager(addressManager)
            .addProtocolAddress("REVENUE_RECEIVER", REVENUE_RECEIVER, ProtocolAddressType.Protocol);

        vm.stopBroadcast();

        return (addressManager, moduleManager, revShareModule);
    }
}
