// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {USDC} from "test/mocks/USDCmock.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract HelperConfig is DeployConstants, Script {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error HelperConfig__InvalidChainId();

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct NetworkConfig {
        address contributionToken;
        address feeClaimAddress;
        address daoMultisig;
        address takadaoOperator;
        address kycProvider;
        address pauseGuardian;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    // Local network state variables
    NetworkConfig public localNetworkConfig;
    mapping(uint256 chainId => NetworkConfig) public networkConfigs;

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor() {
        networkConfigs[ARB_MAINNET_CHAIN_ID] = getArbMainnetConfig();
        networkConfigs[ARB_SEPOLIA_CHAIN_ID] = getArbSepoliaConfig();
        networkConfigs[ETH_SEPOLIA_CHAIN_ID] = getEthSepoliaConfig();
    }

    function getConfigByChainId(uint256 chainId) public returns (NetworkConfig memory) {
        if (networkConfigs[chainId].contributionToken != address(0)) {
            return networkConfigs[chainId];
        } else if (chainId == LOCAL_CHAIN_ID) {
            return getOrCreateAnvilConfig();
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }

    function getArbMainnetConfig() public view returns (NetworkConfig memory mainnetNetworkConfig) {
        mainnetNetworkConfig = NetworkConfig({
            contributionToken: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            feeClaimAddress: feeClaimAddress.mainnet,
            daoMultisig: daoMultisig.mainnet,
            takadaoOperator: takadaoOperator.mainnet,
            kycProvider: kycProvider.mainnet,
            pauseGuardian: pauseGuardian.mainnet
        });
    }

    function getArbSepoliaConfig()
        public
        view
        returns (NetworkConfig memory arbSepoliaNetworkConfig)
    {
        arbSepoliaNetworkConfig = NetworkConfig({
            contributionToken: 0xf9b2DE65196fA500527c576De9312E3c626C7d6a,
            feeClaimAddress: feeClaimAddress.arb_sepolia,
            daoMultisig: daoMultisig.arb_sepolia,
            takadaoOperator: takadaoOperator.arb_sepolia,
            kycProvider: kycProvider.arb_sepolia,
            pauseGuardian: pauseGuardian.arb_sepolia
        });
    }

    function getEthSepoliaConfig()
        public
        view
        returns (NetworkConfig memory ethSepoliaNetworkConfig)
    {
        ethSepoliaNetworkConfig = NetworkConfig({
            contributionToken: 0x4173c6CfB9721cbC32b18Dbaba826715127443e0,
            feeClaimAddress: feeClaimAddress.eth_sepolia,
            daoMultisig: daoMultisig.eth_sepolia,
            takadaoOperator: takadaoOperator.eth_sepolia,
            kycProvider: kycProvider.eth_sepolia,
            pauseGuardian: pauseGuardian.eth_sepolia
        });
    }

    /*//////////////////////////////////////////////////////////////
                              LOCAL CONFIG
    //////////////////////////////////////////////////////////////*/

    function getOrCreateAnvilConfig() public returns (NetworkConfig memory) {
        if (localNetworkConfig.contributionToken != address(0)) {
            return localNetworkConfig;
        }

        vm.startBroadcast();
        USDC usdc = new USDC();
        vm.stopBroadcast();

        return
            NetworkConfig({
                contributionToken: address(usdc),
                feeClaimAddress: feeClaimAddress.local,
                daoMultisig: daoMultisig.local,
                takadaoOperator: takadaoOperator.local,
                kycProvider: kycProvider.local,
                pauseGuardian: pauseGuardian.local
            });
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
