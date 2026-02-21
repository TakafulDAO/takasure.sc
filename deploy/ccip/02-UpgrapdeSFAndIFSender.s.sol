// SPDX-License-Identifier: GNU GPLv3

/// @notice Run in Avax (Mainnet and Fuji), Base (Mainnet and Sepolia), Ethereum (Mainnet and Sepolia),
///         Optimism (Mainnet and Sepolia), Polygon (Mainnet and Amoy)

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFAndIFCcipSender} from "contracts/helpers/chainlink/SFAndIFCcipSender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgrapdeSFAndIFSender is Script, GetContractAddress {
    function run() external returns (address) {
        address senderContractAddress = _getContractAddress(block.chainid, "SFAndIFCcipSender");
        address oldImplementation = Upgrades.getImplementationAddress(senderContractAddress);
        console2.log("Old SF and IF CCIP Sender contract implementation address: ", oldImplementation);

        vm.startBroadcast();

        // Upgrade SFAndIFCcipSender
        Upgrades.upgradeProxy(senderContractAddress, "SFAndIFCcipSender.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(senderContractAddress);
        console2.log("New SF and IF CCIP Sender contract implementation address: ", newImplementation);

        return (newImplementation);
    }
}
