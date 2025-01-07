// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";

abstract contract CodeConstants {
    /*//////////////////////////////////////////////////////////////
                               CHAIN IDS
    //////////////////////////////////////////////////////////////*/
    uint256 public constant ARB_MAINNET_CHAIN_ID = 42161;
    uint256 public constant AVAX_MAINNET_CHAIN_ID = 43114;
    uint256 public constant BASE_MAINNET_CHAIN_ID = 8453;
    uint256 public constant ETH_MAINNET_CHAIN_ID = 1;
    uint256 public constant OP_MAINNET_CHAIN_ID = 10;
    uint256 public constant POL_MAINNET_CHAIN_ID = 137;

    uint256 public constant ARB_SEPOLIA_CHAIN_ID = 421614;
    uint256 public constant AVAX_FUJI_CHAIN_ID = 43113;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant OP_SEPOLIA_CHAIN_ID = 11155420;
    uint256 public constant POL_AMOY_CHAIN_ID = 80002;

    uint256 public constant LOCAL_CHAIN_ID = 31337;

    /*//////////////////////////////////////////////////////////////
                               SELECTORS
    //////////////////////////////////////////////////////////////*/
    uint256 public constant ARB_MAINNET_SELECTOR = 4949039107694359620;
    uint256 public constant AVAX_MAINNET_SELECTOR = 6433500567565415381;
    uint256 public constant BASE_MAINNET_SELECTOR = 15971525489660198786;
    uint256 public constant ETH_MAINNET_SELECTOR = 5009297550715157269;
    uint256 public constant OP_MAINNET_SELECTOR = 3734403246176062136;
    uint256 public constant POL_MAINNET_SELECTOR = 4051577828743386545;

    uint256 public constant ARB_SEPOLIA_SELECTOR = 3478487238524512106;
    uint256 public constant AVAX_FUJI_SELECTOR = 14767482510784806043;
    uint256 public constant BASE_SEPOLIA_SELECTOR = 10344971235874465080;
    uint256 public constant ETH_SEPOLIA_SELECTOR = 16015286601757825753;
    uint256 public constant OP_SEPOLIA_SELECTOR = 10344971235874465080;
    uint256 public constant POL_AMOY_SELECTOR = 10344971235874465080;

    /*//////////////////////////////////////////////////////////////
                               ADDRESSES
    //////////////////////////////////////////////////////////////*/

    struct RouterAddress {
        address arbMainnetRouter;
        address avaxMainnetRouter;
        address baseMainnetRouter;
        address ethMainnetRouter;
        address opMainnetRouter;
        address polMainnetRouter;
        address arbSepoliaRouter;
        address avaxFujiRouter;
        address baseSepoliaRouter;
        address ethSepoliaRouter;
        address opSepoliaRouter;
        address polAmoyRouter;
    }

    struct LinkAddress {
        address arbMainnetLink;
        address avaxMainnetLink;
        address baseMainnetLink;
        address ethMainnetLink;
        address opMainnetLink;
        address polMainnetLink;
        address arbSepoliaLink;
        address avaxFujiLink;
        address baseSepoliaLink;
        address ethSepoliaLink;
        address opSepoliaLink;
        address polAmoyLink;
    }

    struct USDCAddress {
        address arbMainnetUSDC;
        address avaxMainnetUSDC;
        address baseMainnetUSDC;
        address ethMainnetUSDC;
        address opMainnetUSDC;
        address polMainnetUSDC;
        address arbSepoliaUSDC;
        address avaxFujiUSDC;
        address baseSepoliaUSDC;
        address ethSepoliaUSDC;
        address opSepoliaUSDC;
        address polAmoyUSDC;
    }

    RouterAddress public routerAddress =
        RouterAddress({
            arbMainnetRouter: 0x141fa059441E0ca23ce184B6A78bafD2A517DdE8,
            avaxMainnetRouter: 0xF4c7E640EdA248ef95972845a62bdC74237805dB,
            baseMainnetRouter: 0x881e3A65B4d4a04dD529061dd0071cf975F58bCD,
            ethMainnetRouter: 0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D,
            opMainnetRouter: 0x3206695CaE29952f4b0c22a169725a865bc8Ce0f,
            polMainnetRouter: 0x849c5ED5a80F5B408Dd4969b78c2C8fdf0565Bfe,
            arbSepoliaRouter: 0x2a9C5afB0d0e4BAb2BCdaE109EC4b0c4Be15a165,
            avaxFujiRouter: 0xF694E193200268f9a4868e4Aa017A0118C9a8177,
            baseSepoliaRouter: 0xD3b06cEbF099CE7DA4AcCf578aaebFDBd6e88a93,
            ethSepoliaRouter: 0x0BF3dE8c5D3e8A2B34D2BEeB17ABfCeBaf363A59,
            opSepoliaRouter: 0x114A20A10b43D4115e5aeef7345a1A71d2a60C57,
            polAmoyRouter: 0x9C32fCB86BF0f4a1A8921a9Fe46de3198bb884B2
        });

    LinkAddress public linkAddress =
        LinkAddress({
            arbMainnetLink: 0xf97f4df75117a78c1A5a0DBb814Af92458539FB4,
            avaxMainnetLink: 0x5947BB275c521040051D82396192181b413227A3,
            baseMainnetLink: 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196,
            ethMainnetLink: 0x514910771AF9Ca656af840dff83E8264EcF986CA,
            opMainnetLink: 0x350a791Bfc2C21F9Ed5d10980Dad2e2638ffa7f6,
            polMainnetLink: 0xb0897686c545045aFc77CF20eC7A532E3120E0F1,
            arbSepoliaLink: 0xb1D4538B4571d411F07960EF2838Ce337FE1E80E,
            avaxFujiLink: 0x0b9d5D9136855f6FEc3c0993feE6E9CE8a297846,
            baseSepoliaLink: 0xE4aB69C077896252FAFBD49EFD26B5D171A32410,
            ethSepoliaLink: 0x779877A7B0D9E8603169DdbD7836e478b4624789,
            opSepoliaLink: 0xE4aB69C077896252FAFBD49EFD26B5D171A32410,
            polAmoyLink: 0x0Fd9e8d3aF1aaee056EB9e802c3A762a667b1904
        });

    USDCAddress public usdcAddress =
        USDCAddress({
            arbMainnetUSDC: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
            avaxMainnetUSDC: 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E,
            baseMainnetUSDC: 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913,
            ethMainnetUSDC: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            opMainnetUSDC: 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85,
            polMainnetUSDC: 0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359,
            arbSepoliaUSDC: 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d,
            avaxFujiUSDC: 0x5425890298aed601595a70AB815c96711a31Bc65,
            baseSepoliaUSDC: 0x036CbD53842c5426634e7929541eC2318f3dCF7e,
            ethSepoliaUSDC: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238,
            opSepoliaUSDC: 0x5fd84259d66Cd46123540766Be93DFE6D43130D7,
            polAmoyUSDC: 0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582
        });
}

contract CcipHelperConfig is CodeConstants, Script {
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
            usdc: usdcAddress.arbMainnetUSDC
        });
    }

    function getAvaxConfig() public view returns (CCIPNetworkConfig memory avaxCcipConfig) {
        avaxCcipConfig = CCIPNetworkConfig({
            router: routerAddress.avaxMainnetRouter,
            link: linkAddress.avaxMainnetLink,
            usdc: usdcAddress.avaxMainnetUSDC
        });
    }

    function getBaseConfig() public view returns (CCIPNetworkConfig memory baseCcipConfig) {
        baseCcipConfig = CCIPNetworkConfig({
            router: routerAddress.baseMainnetRouter,
            link: linkAddress.baseMainnetLink,
            usdc: usdcAddress.baseMainnetUSDC
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
            usdc: usdcAddress.ethMainnetUSDC
        });
    }

    function getOptimismConfig() public view returns (CCIPNetworkConfig memory optimismCcipConfig) {
        optimismCcipConfig = CCIPNetworkConfig({
            router: routerAddress.opMainnetRouter,
            link: linkAddress.opMainnetLink,
            usdc: usdcAddress.opMainnetUSDC
        });
    }

    function getPolConfig() public view returns (CCIPNetworkConfig memory polCcipConfig) {
        polCcipConfig = CCIPNetworkConfig({
            router: routerAddress.polMainnetRouter,
            link: linkAddress.polMainnetLink,
            usdc: usdcAddress.polMainnetUSDC
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
            usdc: usdcAddress.arbSepoliaUSDC
        });
    }

    function getAvaxFujiConfig() public view returns (CCIPNetworkConfig memory avaxFujiCcipConfig) {
        avaxFujiCcipConfig = CCIPNetworkConfig({
            router: routerAddress.avaxFujiRouter,
            link: linkAddress.avaxFujiLink,
            usdc: usdcAddress.avaxFujiUSDC
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
            usdc: usdcAddress.baseSepoliaUSDC
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
            usdc: usdcAddress.ethSepoliaUSDC
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
            usdc: usdcAddress.opSepoliaUSDC
        });
    }

    function getPolAmoyConfig() public view returns (CCIPNetworkConfig memory polAmoyCcipConfig) {
        polAmoyCcipConfig = CCIPNetworkConfig({
            router: routerAddress.polAmoyRouter,
            link: linkAddress.polAmoyLink,
            usdc: usdcAddress.polAmoyUSDC
        });
    }

    /*//////////////////////////////////////////////////////////////
                              LOCAL CONFIG
    //////////////////////////////////////////////////////////////*/

    function getOrCreateAnvilConfig() public returns (CCIPNetworkConfig memory) {}

    // To avoid this contract to be count in coverage
    function test() external {}
}
