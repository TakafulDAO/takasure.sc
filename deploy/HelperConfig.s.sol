// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {USDC} from "test/mocks/USDCmock.sol";

abstract contract CodeConstants {
    /*//////////////////////////////////////////////////////////////
                               CHAIN IDS
    //////////////////////////////////////////////////////////////*/
    uint256 public constant ARB_MAINNET_CHAIN_ID = 42161;
    uint256 public constant ARB_SEPOLIA_CHAIN_ID = 421614;
    uint256 public constant LOCAL_CHAIN_ID = 31337;

    /*//////////////////////////////////////////////////////////////
                               ACCOUNTS
    //////////////////////////////////////////////////////////////*/

    struct FeeClaimAddress {
        address local;
        address mainnet;
        address sepolia;
    }

    struct DaoMultisig {
        address local;
        address mainnet;
        address sepolia;
    }

    struct TakadaoOperator {
        address local;
        address mainnet;
        address sepolia;
    }

    struct KycProvider {
        address local;
        address mainnet;
        address sepolia;
    }

    struct PauseGuardian {
        address local;
        address mainnet;
        address sepolia;
    }

    struct TokenAdmin {
        address local;
        address mainnet;
        address sepolia;
    }

    FeeClaimAddress public feeClaimAddress =
        FeeClaimAddress({
            local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Avil's account 0
            mainnet: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1, // TODO
            sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1
        });

    DaoMultisig public daoMultisig =
        DaoMultisig({
            local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil's account 0
            mainnet: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1, // TODO
            sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1
        });

    TakadaoOperator public takadaoOperator =
        TakadaoOperator({
            local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil's account 0
            mainnet: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1, // TODO
            sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1
        });

    KycProvider public kycProvider =
        KycProvider({
            local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil's account 0
            mainnet: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1, // TODO
            sepolia: 0x55296ae1c0114A4C20E333571b1DbD40939C80A3
        });

    PauseGuardian public pauseGuardian =
        PauseGuardian({
            local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil's account 0
            mainnet: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1, // TODO
            sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1
        });

    TokenAdmin public tokenAdmin =
        TokenAdmin({
            local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil's account 0
            mainnet: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1, // TODO
            sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1
        });
}

contract HelperConfig is CodeConstants, Script {
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
        networkConfigs[ARB_SEPOLIA_CHAIN_ID] = getArbSepoliaConfig();
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

    function getArbSepoliaConfig() public view returns (NetworkConfig memory sepoliaNetworkConfig) {
        sepoliaNetworkConfig = NetworkConfig({
            contributionToken: 0xf9b2DE65196fA500527c576De9312E3c626C7d6a,
            feeClaimAddress: feeClaimAddress.sepolia,
            daoMultisig: daoMultisig.sepolia,
            takadaoOperator: takadaoOperator.sepolia,
            kycProvider: kycProvider.sepolia,
            pauseGuardian: pauseGuardian.sepolia,
            tokenAdmin: tokenAdmin.sepolia,
            tokenName: "Takasure DAO Token",
            tokenSymbol: "TST",
            functionsRouter: 0x234a5fb5Bd614a7AA2FfAB244D603abFA0Ac5C5C,
            donId: 0x66756e2d617262697472756d2d7365706f6c69612d3100000000000000000000,
            gasLimit: 300000,
            subscriptionId: 123
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
}
