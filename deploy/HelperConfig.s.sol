// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {USDC} from "test/mocks/USDCmock.sol";
import {DeployConstants} from "deploy/DeployConstants.s.sol";

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
        address tokenAdmin;
        string tokenName;
        string tokenSymbol;
        address functionsRouter;
        bytes32 donId;
        uint32 gasLimit;
        uint64 subscriptionId;
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
            pauseGuardian: pauseGuardian.mainnet,
            tokenAdmin: tokenAdmin.mainnet,
            tokenName: "Takasure DAO Token",
            tokenSymbol: "TST",
            functionsRouter: 0x97083E831F8F0638855e2A515c90EdCF158DF238,
            donId: 0x66756e2d617262697472756d2d6d61696e6e65742d3100000000000000000000,
            gasLimit: 300000,
            subscriptionId: 32
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
            pauseGuardian: pauseGuardian.arb_sepolia,
            tokenAdmin: tokenAdmin.arb_sepolia,
            tokenName: "Takasure DAO Token",
            tokenSymbol: "TST",
            functionsRouter: 0x234a5fb5Bd614a7AA2FfAB244D603abFA0Ac5C5C,
            donId: 0x66756e2d617262697472756d2d7365706f6c69612d3100000000000000000000,
            gasLimit: 300000,
            subscriptionId: 123
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
            pauseGuardian: pauseGuardian.eth_sepolia,
            tokenAdmin: tokenAdmin.eth_sepolia,
            tokenName: "Takasure DAO Token",
            tokenSymbol: "TST",
            functionsRouter: 0xb83E47C2bC239B3bf370bc41e1459A34b41238D0,
            donId: 0x66756e2d657468657265756d2d7365706f6c69612d3100000000000000000000,
            gasLimit: 300000,
            subscriptionId: 3966
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
                pauseGuardian: pauseGuardian.local,
                tokenAdmin: tokenAdmin.local,
                tokenName: "Takasure DAO Token",
                tokenSymbol: "TST",
                functionsRouter: 0x234a5fb5Bd614a7AA2FfAB244D603abFA0Ac5C5C, // Same as sepolia
                donId: 0x66756e2d617262697472756d2d7365706f6c69612d3100000000000000000000, // Same as sepolia
                gasLimit: 300000,
                subscriptionId: 123 // Same as sepolia
            });
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
