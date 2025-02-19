// SPDX-License-Identifier: GNU GPLv3

/// @notice Run in Avax (Mainnet and Fuji), Base (Mainnet and Sepolia), Ethereum (Mainnet and Sepolia),
///         Optimism (Mainnet and Sepolia), Polygon (Mainnet and Amoy)

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TLDCcipSender} from "contracts/helpers/chainlink/ccip/TLDCcipSender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract UpgradeTLDCcipSender is Script, GetContractAddress {
    function run() external returns (address) {
        address tldCcipSenderAddress = _getContractAddress(block.chainid, "TLDCcipSender");
        address oldImplementation = Upgrades.getImplementationAddress(tldCcipSenderAddress);
        console2.log("Old TLD CCIP Sender contract implementation address: ", oldImplementation);

        vm.startBroadcast();

        // Upgrade TLDCcipSender
        Upgrades.upgradeProxy(tldCcipSenderAddress, "TLDCcipSender.sol", "");

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(tldCcipSenderAddress);
        console2.log("New TLD CCIP Sender contract implementation address: ", newImplementation);

        return (newImplementation);
    }
}
