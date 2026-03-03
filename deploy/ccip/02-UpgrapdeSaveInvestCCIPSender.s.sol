// SPDX-License-Identifier: GNU GPLv3

/// @notice Run in Avax (Mainnet and Fuji), Base (Mainnet and Sepolia), Ethereum (Mainnet and Sepolia),
///         Optimism (Mainnet and Sepolia), Polygon (Mainnet and Amoy)

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SaveInvestCCIPSender} from "contracts/helpers/chainlink/ccip/SaveInvestCCIPSender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgrapdeSaveInvestCCIPSender is Script, GetContractAddress {
    function run() external returns (address) {
        address senderContractAddress = _getContractAddress(block.chainid, "SaveInvestCCIPSender");
        address oldImplementation = Upgrades.getImplementationAddress(senderContractAddress);
        console2.log("Old Save and Invest CCIP Sender contract implementation address: ", oldImplementation);

        vm.startBroadcast();

        // Upgrade SaveInvestCCIPSender
        Upgrades.upgradeProxy(senderContractAddress, "SaveInvestCCIPSender.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(senderContractAddress);
        console2.log("New Save and Invest CCIP Sender contract implementation address: ", newImplementation);

        return (newImplementation);
    }
}
