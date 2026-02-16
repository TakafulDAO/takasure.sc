// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

abstract contract DeployConstants {
    /*//////////////////////////////////////////////////////////////
                               CHAIN IDS
    //////////////////////////////////////////////////////////////*/
    uint256 public constant ARB_MAINNET_CHAIN_ID = 42161;
    uint256 public constant ARB_SEPOLIA_CHAIN_ID = 421614;
    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant LOCAL_CHAIN_ID = 31337;

    /*//////////////////////////////////////////////////////////////
                               ADDRESSES
    //////////////////////////////////////////////////////////////*/

    // THIS IS NOT the Mock USDC address used for testing purposes which have infinite supply
    struct USDCAddress {
        address arbMainnetUSDC;
        address arbSepoliaUSDC;
    }

    USDCAddress public usdcAddress = USDCAddress({
        arbMainnetUSDC: 0xaf88d065e77c8cC2239327C5EDb3A432268e5831,
        arbSepoliaUSDC: 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d
    });

    struct CouponProvider {
        address arbMainnetCouponProvider;
        address arbSepoliaCouponProvider;
    }

    CouponProvider public couponProvider = CouponProvider({
        arbMainnetCouponProvider: 0x38Ea1c9243962E52ACf92CE4b4bB84879792BCbe,
        arbSepoliaCouponProvider: 0x55296ae1c0114A4C20E333571b1DbD40939C80A3
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

    FeeClaimAddress public feeClaimAddress = FeeClaimAddress({
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

    DaoMultisig public daoMultisig = DaoMultisig({
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

    TakadaoOperator public takadaoOperator = TakadaoOperator({
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

    KycProvider public kycProvider = KycProvider({
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

    PauseGuardian public pauseGuardian = PauseGuardian({
        local: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, // Anvil's account 0
        mainnet: 0xeB82E0b6C73F0837317371Db1Ab537e4f365B2e0, // TODO
        arb_sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1,
        eth_sepolia: 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1
    });

    /*//////////////////////////////////////////////////////////////
                               UNISWAP V3
    //////////////////////////////////////////////////////////////*/

    address public constant UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARBITRUM = 0xC36442b4a4522E871399CD717aBDD847Ab11FE88;
    address public constant UNIVERSAL_ROUTER = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;
    address public constant USDT_ARBITRUM = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9; // USDT on Arbitrum
    address public constant UNI_PERMIT2_ARBITRUM = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // Permit2 on Arbitrum

    address public constant UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARB_SEPOLIA =
        0x6b2937Bde17889EDCf8fbD8dE31C3C2a70Bc4d65;
    address public constant UNIVERSAL_ROUTER_ARB_SEPOLIA = 0x4A7b5Da61326A6379179b40d00F57E5bbDC962c2;

    /*//////////////////////////////////////////////////////////////
                               SAVE FUNDS
    //////////////////////////////////////////////////////////////*/

    uint256 public constant SF_MAX_TVL = 20_000e6;
    address public constant SF_UNI_POOL_ARB_ONE = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;
    // address public constant SF_UNI_POOL_ARB_SEPOLIA = 0x51dff4A270295C78CA668c3B6a8b427269AeaA7f;
    address public constant SF_UNI_POOL_ARB_SEPOLIA = 0x33a0728C87C71A22be84f20493C97f41B3Da00A9;

    address public constant SF_OPERATOR_ARB_ONE = 0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F;
    address public constant SF_FEE_RECEIVER_ARB_ONE = 0x73Fd06671dEbfdebdbc9bdc736E5D2E52c0497DB;
    address public constant SF_PAUSE_GUARDIAN_ARB_ONE = 0xbc946180771866c56981075A5eb9e3Efc7077cb9;
    address public constant SF_BACKEND_ADMIN_ARB_ONE = 0x38Ea1c9243962E52ACf92CE4b4bB84879792BCbe;

    address public constant SF_OPERATOR_ARB_SEPOLIA = 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1;
    address public constant SF_FEE_RECEIVER_ARB_SEPOLIA = 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1;
    address public constant SF_PAUSE_GUARDIAN_ARB_SEPOLIA = 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1;
    address public constant SF_BACKEND_ADMIN_ARB_SEPOLIA = 0x773C677D1c36Cbe7160943A7d75fbf3f72142D32;
}
