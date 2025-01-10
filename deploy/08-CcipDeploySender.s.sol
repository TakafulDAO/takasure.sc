// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Sender} from "contracts/chainlink/ccip/Sender.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";

contract DeploySender is Script {
    uint256 public constant AVAX_FUJI_CHAIN_ID = 43113;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant OP_SEPOLIA_CHAIN_ID = 11155420;
    uint256 public constant POL_AMOY_CHAIN_ID = 80002;

    address public constant RECEIVER_MAINNET = 0x14Eb9897c6b7Ac579e6eFE130287e2729b9A018E; //TODO: deploy first
    address public constant RECEIVER_TESTNET = 0x3cf960FbBA71f53fB9B17FFAcC9388603016795a;

    uint64 public constant ARB_ONE_CHAIN_SELECTOR = 4949039107694359620;
    uint64 public constant ARB_SEPOLIA_CHAIN_SELECTOR = 3478487238524512106;

    function run() external returns (Sender) {
        uint256 chainId = block.chainid;

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(
            block.chainid
        );

        address receiverContract;
        uint64 destinationChainSelector;
        bytes32 salt = "10031960";

        if (
            chainId == AVAX_FUJI_CHAIN_ID ||
            chainId == BASE_SEPOLIA_CHAIN_ID ||
            chainId == ETH_SEPOLIA_CHAIN_ID ||
            chainId == OP_SEPOLIA_CHAIN_ID ||
            chainId == POL_AMOY_CHAIN_ID
        ) {
            receiverContract = RECEIVER_TESTNET;
            destinationChainSelector = ARB_SEPOLIA_CHAIN_SELECTOR;
        } else {
            receiverContract = RECEIVER_MAINNET;
            destinationChainSelector = ARB_ONE_CHAIN_SELECTOR;
        }

        vm.startBroadcast();

        // Deploy Sender contract
        Sender sender = new Sender{salt: salt}(
            config.router,
            config.link,
            config.usdc,
            receiverContract,
            destinationChainSelector
        );

        vm.stopBroadcast();

        return (sender);
    }
}
