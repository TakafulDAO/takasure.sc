// SPDX-License-Identifier: GNU GPLv3

/// @notice Run in Avax (Mainnet and Fuji), Base (Mainnet and Sepolia), Ethereum (Mainnet and Sepolia),
///         Optimism (Mainnet and Sepolia), Polygon (Mainnet and Amoy)

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TLDCcipSender} from "contracts/chainlink/ccip/TLDCcipSender.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract DeployTLDCcipSender is Script, DeployConstants, GetContractAddress {
    function run() external returns (address) {
        uint256 chainId = block.chainid;

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(
            chainId
        );

        address receiverContractAddress;
        uint64 destinationChainSelector;
        bytes32 salt = "2550";

        if (
            chainId == AVAX_FUJI_CHAIN_ID ||
            chainId == BASE_SEPOLIA_CHAIN_ID ||
            chainId == ETH_SEPOLIA_CHAIN_ID ||
            chainId == OP_SEPOLIA_CHAIN_ID ||
            chainId == POL_AMOY_CHAIN_ID
        ) {
            receiverContractAddress = _getContractAddress(ARB_SEPOLIA_CHAIN_ID, "TLDCcipReceiver");
            destinationChainSelector = ARB_SEPOLIA_SELECTOR;
        } else {
            receiverContractAddress = _getContractAddress(ARB_MAINNET_CHAIN_ID, "TLDCcipReceiver");
            destinationChainSelector = ARB_MAINNET_SELECTOR;
        }

        vm.startBroadcast();

        // Deploy implementation
        TLDCcipSender sender = new TLDCcipSender();

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(sender), "");

        TLDCcipSender(address(proxy)).initialize(
            config.router,
            config.link,
            receiverContractAddress,
            destinationChainSelector,
            config.senderOwner,
            config.couponProvider
        );

        vm.stopBroadcast();

        return address(proxy);
    }
}
