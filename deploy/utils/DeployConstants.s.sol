// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

abstract contract DeployConstants {
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
    uint64 public constant ARB_MAINNET_SELECTOR = 4949039107694359620;
    uint64 public constant AVAX_MAINNET_SELECTOR = 6433500567565415381;
    uint64 public constant BASE_MAINNET_SELECTOR = 15971525489660198786;
    uint64 public constant ETH_MAINNET_SELECTOR = 5009297550715157269;
    uint64 public constant OP_MAINNET_SELECTOR = 3734403246176062136;
    uint64 public constant POL_MAINNET_SELECTOR = 4051577828743386545;

    uint64 public constant ARB_SEPOLIA_SELECTOR = 3478487238524512106;
    uint64 public constant AVAX_FUJI_SELECTOR = 14767482510784806043;
    uint64 public constant BASE_SEPOLIA_SELECTOR = 10344971235874465080;
    uint64 public constant ETH_SEPOLIA_SELECTOR = 16015286601757825753;
    uint64 public constant OP_SEPOLIA_SELECTOR = 5224473277236331295;
    uint64 public constant POL_AMOY_SELECTOR = 16281711391670634445;

    /*//////////////////////////////////////////////////////////////
                               ADDRESSES
    //////////////////////////////////////////////////////////////*/

    // Chainlink CCIP Router Addresses
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

    // Link Token. Used for Chainlink CCIP
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

    // This is the USDC address for each chain used for the Chainlink CCIP
    // THIS IS NOT the Mock USDC address used for testing purposes which have infinite supply
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

    struct SenderOwner {
        address avaxMainnetSenderOwner;
        address baseMainnetSenderOwner;
        address ethMainnetSenderOwner;
        address opMainnetSenderOwner;
        address polMainnetSenderOwner;
        address avaxFujiSenderOwner;
        address baseSepoliaSenderOwner;
        address ethSepoliaSenderOwner;
        address opSepoliaSenderOwner;
        address polAmoySenderOwner;
    }

    SenderOwner public senderOwner =
        SenderOwner({
            avaxMainnetSenderOwner: 0xeB82E0b6C73F0837317371Db1Ab537e4f365B2e0,
            baseMainnetSenderOwner: 0xeB82E0b6C73F0837317371Db1Ab537e4f365B2e0,
            ethMainnetSenderOwner: 0xeB82E0b6C73F0837317371Db1Ab537e4f365B2e0,
            opMainnetSenderOwner: 0xeB82E0b6C73F0837317371Db1Ab537e4f365B2e0,
            polMainnetSenderOwner: 0xeB82E0b6C73F0837317371Db1Ab537e4f365B2e0,
            avaxFujiSenderOwner: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1,
            baseSepoliaSenderOwner: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1,
            ethSepoliaSenderOwner: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1,
            opSepoliaSenderOwner: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1,
            polAmoySenderOwner: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1
        });

    struct CouponProvider {
        address arbMainnetCouponProvider;
        address avaxMainnetCouponProvider;
        address baseMainnetCouponProvider;
        address ethMainnetCouponProvider;
        address opMainnetCouponProvider;
        address polMainnetCouponProvider;
        address arbSepoliaCouponProvider;
        address avaxFujiCouponProvider;
        address baseSepoliaCouponProvider;
        address ethSepoliaCouponProvider;
        address opSepoliaCouponProvider;
        address polAmoyCouponProvider;
    }

    CouponProvider public couponProvider =
        CouponProvider({
            arbMainnetCouponProvider: 0x38Ea1c9243962E52ACf92CE4b4bB84879792BCbe,
            avaxMainnetCouponProvider: 0x38Ea1c9243962E52ACf92CE4b4bB84879792BCbe,
            baseMainnetCouponProvider: 0x38Ea1c9243962E52ACf92CE4b4bB84879792BCbe,
            ethMainnetCouponProvider: 0x38Ea1c9243962E52ACf92CE4b4bB84879792BCbe,
            opMainnetCouponProvider: 0x38Ea1c9243962E52ACf92CE4b4bB84879792BCbe,
            polMainnetCouponProvider: 0x38Ea1c9243962E52ACf92CE4b4bB84879792BCbe,
            arbSepoliaCouponProvider: 0x55296ae1c0114A4C20E333571b1DbD40939C80A3,
            avaxFujiCouponProvider: 0x55296ae1c0114A4C20E333571b1DbD40939C80A3,
            baseSepoliaCouponProvider: 0x55296ae1c0114A4C20E333571b1DbD40939C80A3,
            ethSepoliaCouponProvider: 0x55296ae1c0114A4C20E333571b1DbD40939C80A3,
            opSepoliaCouponProvider: 0x55296ae1c0114A4C20E333571b1DbD40939C80A3,
            polAmoyCouponProvider: 0x55296ae1c0114A4C20E333571b1DbD40939C80A3
        });

    /*//////////////////////////////////////////////////////////////
                               ACCOUNTS
    //////////////////////////////////////////////////////////////*/

    // The one that receive the fees from the protocol
    // Used only in deployment, can be change after deployment for a multisig
    struct FeeClaimAddress {
        address local;
        address mainnet;
        address arb_sepolia;
        address eth_sepolia;
    }

    FeeClaimAddress public feeClaimAddress =
        FeeClaimAddress({
            local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Avil's account 0
            mainnet: 0xeB82E0b6C73F0837317371Db1Ab537e4f365B2e0, // TODO
            arb_sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1,
            eth_sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1
        });

    // DAO Multisig wallet. It has some special permissions in the protocol
    struct DaoMultisig {
        address local;
        address mainnet;
        address arb_sepolia;
        address eth_sepolia;
    }

    DaoMultisig public daoMultisig =
        DaoMultisig({
            local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil's account 0
            mainnet: 0xeB82E0b6C73F0837317371Db1Ab537e4f365B2e0, // TODO
            arb_sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1,
            eth_sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1
        });

    // Address with some special permissions in the protocol
    // Used only in deployment, can be change after deployment for a multisig
    struct TakadaoOperator {
        address local;
        address mainnet;
        address arb_sepolia;
        address eth_sepolia;
    }

    TakadaoOperator public takadaoOperator =
        TakadaoOperator({
            local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil's account 0
            mainnet: 0xeB82E0b6C73F0837317371Db1Ab537e4f365B2e0,
            arb_sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1,
            eth_sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1
        });

    // Address with privilege to manage the KYC for each user
    struct KycProvider {
        address local;
        address mainnet;
        address arb_sepolia;
        address eth_sepolia;
    }

    KycProvider public kycProvider =
        KycProvider({
            local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil's account 0
            mainnet: 0x2b212e37A5619191694Ad0E99fD6F76e45fdb2Ba,
            arb_sepolia: 0x55296ae1c0114A4C20E333571b1DbD40939C80A3,
            eth_sepolia: 0x55296ae1c0114A4C20E333571b1DbD40939C80A3
        });

    // Address with privilege to pause the protocol
    struct PauseGuardian {
        address local;
        address mainnet;
        address arb_sepolia;
        address eth_sepolia;
    }

    PauseGuardian public pauseGuardian =
        PauseGuardian({
            local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil's account 0
            mainnet: 0xeB82E0b6C73F0837317371Db1Ab537e4f365B2e0, // TODO
            arb_sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1,
            eth_sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1
        });

    // Address with privilege to manage the token
    struct TokenAdmin {
        address local;
        address mainnet;
        address arb_sepolia;
        address eth_sepolia;
    }

    TokenAdmin public tokenAdmin =
        TokenAdmin({
            local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil's account 0
            mainnet: 0xeB82E0b6C73F0837317371Db1Ab537e4f365B2e0, // TODO
            arb_sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1,
            eth_sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1
        });

    /*//////////////////////////////////////////////////////////////
                         BM FETCH SCRIPT ROOTS
    //////////////////////////////////////////////////////////////*/

    string constant MAINNET_SCRIPT_ROOT = "/scripts/chainlink-functions/bmFetchCodeMainnet.js";
    string constant TESTNET_SCRIPT_ROOT = "/scripts/chainlink-functions/bmFetchCodeTestnet.js";
    string constant UAT_SCRIPT_ROOT = "/scripts/chainlink-functions/bmFetchCodeUat.js";
}
