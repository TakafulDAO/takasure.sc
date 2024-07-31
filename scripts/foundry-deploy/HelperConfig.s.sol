// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {USDC} from "test/foundry-tests/mocks/USDCmock.sol";

abstract contract CodeConstants {
    /*//////////////////////////////////////////////////////////////
                               CHAIN IDS
    //////////////////////////////////////////////////////////////*/
    uint256 public constant ARB_SEPOLIA_CHAIN_ID = 421614;
    uint256 public constant LOCAL_CHAIN_ID = 31337;

    /*//////////////////////////////////////////////////////////////
                               ACCOUNTS
    //////////////////////////////////////////////////////////////*/

    // Anvil's account 0 private key
    uint256 public DEFAULT_ANVIL_PRIVATE_KEY =
        0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    // Anvil's account 1 public address
    address public feeClaimAddressLocal = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    // Anvil's account 2 public address
    address public daoOperatorLocal = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;
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
        uint256 deployerKey;
        address feeClaimAddress;
        address daoOperator;
        address router;
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
        networkConfigs[ARB_SEPOLIA_CHAIN_ID] = getArbSepoliaEthConfig();
        networkConfigs[LOCAL_CHAIN_ID] = getOrCreateAnvilConfig();
    }

    function getConfig() public returns (NetworkConfig memory) {
        return getConfigByChainId(block.chainid);
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

    function getArbSepoliaEthConfig()
        public
        view
        returns (NetworkConfig memory sepoliaNetworkConfig)
    {
        sepoliaNetworkConfig = NetworkConfig({
            contributionToken: 0xf9b2DE65196fA500527c576De9312E3c626C7d6a,
            deployerKey: vm.envUint("TESTNET_DEPLOYER_PK_FOUNDRY"),
            feeClaimAddress: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1,
            daoOperator: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1,
            router: 0x234a5fb5Bd614a7AA2FfAB244D603abFA0Ac5C5C,
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
                deployerKey: DEFAULT_ANVIL_PRIVATE_KEY,
                feeClaimAddress: feeClaimAddressLocal,
                daoOperator: daoOperatorLocal,
                router: 0x234a5fb5Bd614a7AA2FfAB244D603abFA0Ac5C5C,
                donId: 0x66756e2d617262697472756d2d7365706f6c69612d3100000000000000000000,
                gasLimit: 300000,
                subscriptionId: 123
            });
    }
}
