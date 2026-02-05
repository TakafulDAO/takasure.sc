// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {UniswapV3MathHelper} from "contracts/helpers/uniswapHelpers/UniswapV3MathHelper.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract DeploySFMainnet is Script, DeployConstants {
    AddressManager addressManager;
    SFVault sfVault;
    SFStrategyAggregator sfStrategyAggregator;
    SFUniswapV3Strategy sfUniswapV3Strategy;

    address constant OPERATOR_MULTISIG = 0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F;
    address constant BACKEND = 0x38Ea1c9243962E52ACf92CE4b4bB84879792BCbe; // TODO: Confirm this one
    address constant FEE_RECEIVER_MULTISIG = 0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F; // TODO: Change this one
    address constant POOL = 0x905dfCD5649217c42684f23958568e533C711Aa3; // TODO: Change this one

    uint256 constant MAX_TVL = 20_000e6; // TODO: Change this one
    int24 constant TICK_LOWER = -600; // TODO: Change this one
    int24 constant TICK_UPPER = 600; // TODO: Change this one

    function run()
        external
        returns (
            address addressManagerAddr,
            address sfVaultAddr,
            address sfStrategyAggregatorAddr,
            address sfUniswapV3StrategyAddr,
            address uniswapV3MathHelperAddr
        )
    {
        // uint256 chainId = block.chainid;
        // HelperConfig helperConfig = new HelperConfig();
        // HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(chainId);

        vm.startBroadcast();

        // Deploy AddressManager
        addressManagerAddr =
            Upgrades.deployUUPSProxy("AddressManager.sol", abi.encodeCall(AddressManager.initialize, (msg.sender)));

        addressManager = AddressManager(addressManagerAddr);
        console2.log("AddressManager deployed at:", addressManagerAddr);

        // Deploy SFVault
        sfVaultAddr = Upgrades.deployUUPSProxy(
            "SFVault.sol",
            abi.encodeCall(
                SFVault.initialize,
                (IAddressManager(addressManagerAddr), IERC20(usdcAddress.arbMainnetUSDC), "TLDSaveVault", "TLDSV")
            )
        );
        sfVault = SFVault(sfVaultAddr);
        console2.log("SFVault deployed at:", sfVaultAddr);

        // Deploy SFStrategyAggregator
        sfStrategyAggregatorAddr = Upgrades.deployUUPSProxy(
            "SFStrategyAggregator.sol",
            abi.encodeCall(
                SFStrategyAggregator.initialize,
                (IAddressManager(addressManagerAddr), IERC20(usdcAddress.arbMainnetUSDC))
            )
        );
        sfStrategyAggregator = SFStrategyAggregator(sfStrategyAggregatorAddr);
        console2.log("SFStrategyAggregator deployed at:", sfStrategyAggregatorAddr);

        // Deploy UniswapV3MathHelper
        uniswapV3MathHelperAddr = address(new UniswapV3MathHelper());

        // Deploy SFUniswapV3Strategy
        sfUniswapV3StrategyAddr = Upgrades.deployUUPSProxy(
            "SFUniswapV3Strategy.sol",
            abi.encodeCall(
                SFUniswapV3Strategy.initialize,
                (
                    IAddressManager(addressManagerAddr),
                    sfVaultAddr,
                    IERC20(usdcAddress.arbMainnetUSDC),
                    IERC20(USDT_ARBITRUM),
                    POOL,
                    UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARBITRUM,
                    uniswapV3MathHelperAddr,
                    MAX_TVL,
                    UNIVERSAL_ROUTER,
                    TICK_LOWER,
                    TICK_UPPER
                )
            )
        );
        sfUniswapV3Strategy = SFUniswapV3Strategy(sfUniswapV3StrategyAddr);
        console2.log("SFUniswapV3Strategy deployed at:", sfUniswapV3StrategyAddr);

        // Creating roles in AddressManager
        addressManager.createNewRole(Roles.OPERATOR);
        addressManager.createNewRole(Roles.PAUSE_GUARDIAN);
        addressManager.createNewRole(Roles.BACKEND_ADMIN);
        addressManager.createNewRole(Roles.KEEPER);
        console2.log("Roles created in AddressManager");

        // Propose initial role holders
        // Initially the operator multisig will hold multiple roles
        addressManager.proposeRoleHolder(Roles.OPERATOR, OPERATOR_MULTISIG);
        addressManager.proposeRoleHolder(Roles.PAUSE_GUARDIAN, OPERATOR_MULTISIG);
        addressManager.proposeRoleHolder(Roles.KEEPER, OPERATOR_MULTISIG);
        addressManager.proposeRoleHolder(Roles.BACKEND_ADMIN, BACKEND);
        console2.log("Initial role holders proposed in AddressManager");

        // Add addresses
        addressManager.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", FEE_RECEIVER_MULTISIG, ProtocolAddressType.Admin);
        addressManager.addProtocolAddress("ADMIN__OPERATOR", OPERATOR_MULTISIG, ProtocolAddressType.Admin);
        addressManager.addProtocolAddress("ADMIN__BACKEND_ADMIN", BACKEND, ProtocolAddressType.Admin);
        addressManager.addProtocolAddress("PROTOCOL__SF_VAULT", sfVaultAddr, ProtocolAddressType.Protocol);
        addressManager.addProtocolAddress(
            "PROTOCOL__SF_AGGREGATOR", sfStrategyAggregatorAddr, ProtocolAddressType.Protocol
        );
        addressManager.addProtocolAddress(
            "HELPER__UNISWAP_V3_MATH_HELPER", uniswapV3MathHelperAddr, ProtocolAddressType.Helper
        );
        addressManager.addProtocolAddress(
            "PROTOCOL__SF_UNISWAP_V3_STRATEGY", sfUniswapV3StrategyAddr, ProtocolAddressType.Protocol
        );

        // Also some usefull external addresses
        addressManager.addProtocolAddress("EXTERNAL__USDC", usdcAddress.arbMainnetUSDC, ProtocolAddressType.External);
        addressManager.addProtocolAddress("EXTERNAL__USDT", USDT_ARBITRUM, ProtocolAddressType.External);
        addressManager.addProtocolAddress(
            "EXTERNAL__UNI_V3_POS_MANAGER", UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARBITRUM, ProtocolAddressType.External
        );
        addressManager.addProtocolAddress(
            "EXTERNAL__UNI_UNIVERSAL_ROUTER", UNIVERSAL_ROUTER, ProtocolAddressType.External
        );
        addressManager.addProtocolAddress("EXTERNAL__UNI_PERMIT_2", UNI_PERMIT2_ARBITRUM, ProtocolAddressType.External);
        console2.log("Protocol addresses added in AddressManager");

        // Transfer Ownership to Operator Multisig
        addressManager.transferOwnership(OPERATOR_MULTISIG);
        console2.log("AddressManager ownership transferred to:", OPERATOR_MULTISIG);

        vm.stopBroadcast();

        return
            (
                addressManagerAddr,
                sfVaultAddr,
                sfStrategyAggregatorAddr,
                sfUniswapV3StrategyAddr,
                uniswapV3MathHelperAddr
            );
    }
}

/*
Pemding calls in the operator multisig after deployment:
vault.setERC721ApprovalForAll({nft: UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARBITRUM, operator: uniV3Strategy, approved: true});
vault.whitelistToken(usdt);
aggregator.addSubStrategy({strategy: uniV3Strategy, targetWeightBPS: 100});
addressManager.acceptOwnership();
addressManager.acceptProposedRole(Roles.OPERATOR);
addressManager.acceptProposedRole(Roles.PAUSE_GUARDIAN);
addressManager.acceptProposedRole(Roles.KEEPER);
addressManager.acceptProposedRole(Roles.BACKEND_ADMIN);

Checks
vault.isTokenWhitelisted(usdt) == true
vault.isTokenWhitelisted(usdc) == true
aggregator.getSubStrategies()
addressManager.owner() == OPERATOR_MULTISIG
*/
