// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract CcipHelperConfig is DeployConstants, Script {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error CcipHelperConfig__InvalidChainId();

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    struct CCIPNetworkConfig {
        address router;
        address link;
        address usdc;
        address senderOwner;
        address couponProvider;
    }

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    // Local network state variables
    CCIPNetworkConfig public localNetworkConfig;
    mapping(uint256 chainId => CCIPNetworkConfig) public ccipNetworkConfigs;

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    constructor() {
        ccipNetworkConfigs[ARB_MAINNET_CHAIN_ID] = getArbMainnetConfig();
        ccipNetworkConfigs[AVAX_MAINNET_CHAIN_ID] = getAvaxConfig();
        ccipNetworkConfigs[BASE_MAINNET_CHAIN_ID] = getBaseConfig();
        ccipNetworkConfigs[ETH_MAINNET_CHAIN_ID] = getEthMainnetConfig();
        ccipNetworkConfigs[OP_MAINNET_CHAIN_ID] = getOptimismConfig();
        ccipNetworkConfigs[POL_MAINNET_CHAIN_ID] = getPolConfig();

        ccipNetworkConfigs[ARB_SEPOLIA_CHAIN_ID] = getArbSepoliaConfig();
        ccipNetworkConfigs[AVAX_FUJI_CHAIN_ID] = getAvaxFujiConfig();
        ccipNetworkConfigs[BASE_SEPOLIA_CHAIN_ID] = getBaseSepoliaConfig();
        ccipNetworkConfigs[ETH_SEPOLIA_CHAIN_ID] = getEthSepoliaConfig();
        ccipNetworkConfigs[OP_SEPOLIA_CHAIN_ID] = getOpSepoliaConfig();
        ccipNetworkConfigs[POL_AMOY_CHAIN_ID] = getPolAmoyConfig();
    }

    function getConfigByChainId(uint256 chainId) public returns (CCIPNetworkConfig memory) {
        if (ccipNetworkConfigs[chainId].usdc != address(0)) {
            return ccipNetworkConfigs[chainId];
        } else if (chainId == LOCAL_CHAIN_ID) {
            return getOrCreateAnvilConfig();
        } else {
            revert CcipHelperConfig__InvalidChainId();
        }
    }

    function getArbMainnetConfig()
        public
        view
        returns (CCIPNetworkConfig memory arbMainnetCcipConfig)
    {
        arbMainnetCcipConfig = CCIPNetworkConfig({
            router: routerAddress.arbMainnetRouter,
            link: linkAddress.arbMainnetLink,
            usdc: usdcAddress.arbMainnetUSDC,
            senderOwner: address(0),
            couponProvider: couponProvider.arbMainnetCouponProvider
        });
    }

    function getAvaxConfig() public view returns (CCIPNetworkConfig memory avaxCcipConfig) {
        avaxCcipConfig = CCIPNetworkConfig({
            router: routerAddress.avaxMainnetRouter,
            link: linkAddress.avaxMainnetLink,
            usdc: usdcAddress.avaxMainnetUSDC,
            senderOwner: senderOwner.avaxMainnetSenderOwner,
            couponProvider: couponProvider.avaxMainnetCouponProvider
        });
    }

    function getBaseConfig() public view returns (CCIPNetworkConfig memory baseCcipConfig) {
        baseCcipConfig = CCIPNetworkConfig({
            router: routerAddress.baseMainnetRouter,
            link: linkAddress.baseMainnetLink,
            usdc: usdcAddress.baseMainnetUSDC,
            senderOwner: senderOwner.baseMainnetSenderOwner,
            couponProvider: couponProvider.baseMainnetCouponProvider
        });
    }

    function getEthMainnetConfig()
        public
        view
        returns (CCIPNetworkConfig memory ethMainnetCcipConfig)
    {
        ethMainnetCcipConfig = CCIPNetworkConfig({
            router: routerAddress.ethMainnetRouter,
            link: linkAddress.ethMainnetLink,
            usdc: usdcAddress.ethMainnetUSDC,
            senderOwner: senderOwner.ethMainnetSenderOwner,
            couponProvider: couponProvider.ethMainnetCouponProvider
        });
    }

    function getOptimismConfig() public view returns (CCIPNetworkConfig memory optimismCcipConfig) {
        optimismCcipConfig = CCIPNetworkConfig({
            router: routerAddress.opMainnetRouter,
            link: linkAddress.opMainnetLink,
            usdc: usdcAddress.opMainnetUSDC,
            senderOwner: senderOwner.opMainnetSenderOwner,
            couponProvider: couponProvider.opMainnetCouponProvider
        });
    }

    function getPolConfig() public view returns (CCIPNetworkConfig memory polCcipConfig) {
        polCcipConfig = CCIPNetworkConfig({
            router: routerAddress.polMainnetRouter,
            link: linkAddress.polMainnetLink,
            usdc: usdcAddress.polMainnetUSDC,
            senderOwner: senderOwner.polMainnetSenderOwner,
            couponProvider: couponProvider.polMainnetCouponProvider
        });
    }

    function getArbSepoliaConfig()
        public
        view
        returns (CCIPNetworkConfig memory arbSepoliaCcipConfig)
    {
        arbSepoliaCcipConfig = CCIPNetworkConfig({
            router: routerAddress.arbSepoliaRouter,
            link: linkAddress.arbSepoliaLink,
            usdc: usdcAddress.arbSepoliaUSDC,
            senderOwner: address(0),
            couponProvider: couponProvider.arbSepoliaCouponProvider
        });
    }

    function getAvaxFujiConfig() public view returns (CCIPNetworkConfig memory avaxFujiCcipConfig) {
        avaxFujiCcipConfig = CCIPNetworkConfig({
            router: routerAddress.avaxFujiRouter,
            link: linkAddress.avaxFujiLink,
            usdc: usdcAddress.avaxFujiUSDC,
            senderOwner: senderOwner.avaxFujiSenderOwner,
            couponProvider: couponProvider.avaxFujiCouponProvider
        });
    }

    function getBaseSepoliaConfig()
        public
        view
        returns (CCIPNetworkConfig memory baseSepoliaCcipConfig)
    {
        baseSepoliaCcipConfig = CCIPNetworkConfig({
            router: routerAddress.baseSepoliaRouter,
            link: linkAddress.baseSepoliaLink,
            usdc: usdcAddress.baseSepoliaUSDC,
            senderOwner: senderOwner.baseSepoliaSenderOwner,
            couponProvider: couponProvider.baseSepoliaCouponProvider
        });
    }

    function getEthSepoliaConfig()
        public
        view
        returns (CCIPNetworkConfig memory ethSepoliaCcipConfig)
    {
        ethSepoliaCcipConfig = CCIPNetworkConfig({
            router: routerAddress.ethSepoliaRouter,
            link: linkAddress.ethSepoliaLink,
            usdc: usdcAddress.ethSepoliaUSDC,
            senderOwner: senderOwner.ethSepoliaSenderOwner,
            couponProvider: couponProvider.ethSepoliaCouponProvider
        });
    }

    function getOpSepoliaConfig()
        public
        view
        returns (CCIPNetworkConfig memory opSepoliaCcipConfig)
    {
        opSepoliaCcipConfig = CCIPNetworkConfig({
            router: routerAddress.opSepoliaRouter,
            link: linkAddress.opSepoliaLink,
            usdc: usdcAddress.opSepoliaUSDC,
            senderOwner: senderOwner.opSepoliaSenderOwner,
            couponProvider: couponProvider.opSepoliaCouponProvider
        });
    }

    function getPolAmoyConfig() public view returns (CCIPNetworkConfig memory polAmoyCcipConfig) {
        polAmoyCcipConfig = CCIPNetworkConfig({
            router: routerAddress.polAmoyRouter,
            link: linkAddress.polAmoyLink,
            usdc: usdcAddress.polAmoyUSDC,
            senderOwner: senderOwner.polAmoySenderOwner,
            couponProvider: couponProvider.polAmoyCouponProvider
        });
    }

    /*//////////////////////////////////////////////////////////////
                              LOCAL CONFIG
    //////////////////////////////////////////////////////////////*/

    function getOrCreateAnvilConfig() public returns (CCIPNetworkConfig memory) {}

    // To avoid this contract to be count in coverage
    function test() external {}
}
