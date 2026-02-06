// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {SFTwapValuator} from "contracts/saveFunds/SFTwapValuator.sol";
import {SFVaultLens} from "contracts/saveFunds/SFVaultLens.sol";
import {SFStrategyAggregatorLens} from "contracts/saveFunds/SFStrategyAggregatorLens.sol";
import {SFUniswapV3StrategyLens} from "contracts/saveFunds/SFUniswapV3StrategyLens.sol";
import {SFLens} from "contracts/saveFunds/SFLens.sol";
import {UniswapV3MathHelper} from "contracts/helpers/uniswapHelpers/UniswapV3MathHelper.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {DeploymentArtifacts} from "deploy/utils/DeploymentArtifacts.s.sol";

contract DeploySFMainnet is DeploymentArtifacts {
    address constant OPERATOR_MULTISIG = 0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F;
    address constant BACKEND = 0x38Ea1c9243962E52ACf92CE4b4bB84879792BCbe;
    address constant FEE_RECEIVER_MULTISIG = 0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F; // TODO: Change this one
    address constant POOL = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;

    uint256 constant MAX_TVL = 20_000e6;
    int24 constant TICK_LOWER = 2;
    int24 constant TICK_UPPER = 3;

    function run()
        external
        returns (
            address addressManagerAddr,
            address sfVaultAddr,
            address sfStrategyAggregatorAddr,
            address sfUniswapV3StrategyAddr,
            address uniswapV3MathHelperAddr,
            address sfTwapValuatorAddr,
            address sfVaultLensAddr,
            address sfStrategyAggregatorLensAddr,
            address sfUniswapV3StrategyLensAddr,
            address sfLensAddr
        )
    {
        vm.startBroadcast();

        // Deploy AddressManager
        addressManagerAddr =
            Upgrades.deployUUPSProxy("AddressManager.sol", abi.encodeCall(AddressManager.initialize, (msg.sender)));

        AddressManager addressManager = AddressManager(addressManagerAddr);
        console2.log("AddressManager deployed at:", addressManagerAddr);

        // Deploy SFVault
        sfVaultAddr = Upgrades.deployUUPSProxy(
            "SFVault.sol",
            abi.encodeCall(
                SFVault.initialize,
                (IAddressManager(addressManagerAddr), IERC20(usdcAddress.arbMainnetUSDC), "TLDSaveVault", "TLDSV")
            )
        );
        console2.log("SFVault deployed at:", sfVaultAddr);

        // Deploy SFStrategyAggregator
        sfStrategyAggregatorAddr = Upgrades.deployUUPSProxy(
            "SFStrategyAggregator.sol",
            abi.encodeCall(
                SFStrategyAggregator.initialize,
                (IAddressManager(addressManagerAddr), IERC20(usdcAddress.arbMainnetUSDC))
            )
        );
        console2.log("SFStrategyAggregator deployed at:", sfStrategyAggregatorAddr);

        // Deploy SFTwapValuator
        sfTwapValuatorAddr = address(new SFTwapValuator(IAddressManager(addressManagerAddr), 1800));
        console2.log("SFTwapValuator deployed at:", sfTwapValuatorAddr);

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
        console2.log("SFUniswapV3Strategy deployed at:", sfUniswapV3StrategyAddr);

        // Deploy lens contracts
        sfVaultLensAddr = address(new SFVaultLens());
        sfStrategyAggregatorLensAddr = address(new SFStrategyAggregatorLens());
        sfUniswapV3StrategyLensAddr = address(new SFUniswapV3StrategyLens());
        sfLensAddr = address(new SFLens(sfVaultLensAddr, sfStrategyAggregatorLensAddr, sfUniswapV3StrategyLensAddr));

        console2.log("SFVaultLens deployed at:", sfVaultLensAddr);
        console2.log("SFStrategyAggregatorLens deployed at:", sfStrategyAggregatorLensAddr);
        console2.log("SFUniswapV3StrategyLens deployed at:", sfUniswapV3StrategyLensAddr);
        console2.log("SFLens deployed at:", sfLensAddr);

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
            "PROTOCOL__SF_UNISWAP_V3_STRATEGY", sfUniswapV3StrategyAddr, ProtocolAddressType.Protocol
        );
        addressManager.addProtocolAddress(
            "HELPER__UNISWAP_V3_MATH_HELPER", uniswapV3MathHelperAddr, ProtocolAddressType.Helper
        );
        addressManager.addProtocolAddress("HELPER__SF_VALUATOR", sfTwapValuatorAddr, ProtocolAddressType.Helper);
        addressManager.addProtocolAddress("HELPER__SF_VAULT_LENS", sfVaultLensAddr, ProtocolAddressType.Helper);
        addressManager.addProtocolAddress(
            "HELPER__SF_STRATEGY_AGG_LENS", sfStrategyAggregatorLensAddr, ProtocolAddressType.Helper
        );
        addressManager.addProtocolAddress(
            "HELPER__SF_UNIV3_STRAT_LENS", sfUniswapV3StrategyLensAddr, ProtocolAddressType.Helper
        );
        addressManager.addProtocolAddress("HELPER__SF_LENS", sfLensAddr, ProtocolAddressType.Helper);

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

        ProtocolAddressRow[] memory protocolAddresses = new ProtocolAddressRow[](17);
        protocolAddresses[0] = ProtocolAddressRow({
            name: "ADMIN__SF_FEE_RECEIVER", addr: FEE_RECEIVER_MULTISIG, addrType: ProtocolAddressType.Admin
        });
        protocolAddresses[1] =
            ProtocolAddressRow({name: "ADMIN__OPERATOR", addr: OPERATOR_MULTISIG, addrType: ProtocolAddressType.Admin});
        protocolAddresses[2] =
            ProtocolAddressRow({name: "ADMIN__BACKEND_ADMIN", addr: BACKEND, addrType: ProtocolAddressType.Admin});
        protocolAddresses[3] =
            ProtocolAddressRow({name: "PROTOCOL__SF_VAULT", addr: sfVaultAddr, addrType: ProtocolAddressType.Protocol});
        protocolAddresses[4] = ProtocolAddressRow({
            name: "PROTOCOL__SF_AGGREGATOR", addr: sfStrategyAggregatorAddr, addrType: ProtocolAddressType.Protocol
        });
        protocolAddresses[5] = ProtocolAddressRow({
            name: "PROTOCOL__SF_UNISWAP_V3_STRATEGY",
            addr: sfUniswapV3StrategyAddr,
            addrType: ProtocolAddressType.Protocol
        });
        protocolAddresses[6] = ProtocolAddressRow({
            name: "HELPER__UNISWAP_V3_MATH_HELPER", addr: uniswapV3MathHelperAddr, addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[7] = ProtocolAddressRow({
            name: "HELPER__SF_VALUATOR", addr: sfTwapValuatorAddr, addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[8] = ProtocolAddressRow({
            name: "HELPER__SF_VAULT_LENS", addr: sfVaultLensAddr, addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[9] = ProtocolAddressRow({
            name: "HELPER__SF_STRATEGY_AGG_LENS",
            addr: sfStrategyAggregatorLensAddr,
            addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[10] = ProtocolAddressRow({
            name: "HELPER__SF_UNIV3_STRAT_LENS", addr: sfUniswapV3StrategyLensAddr, addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[11] =
            ProtocolAddressRow({name: "HELPER__SF_LENS", addr: sfLensAddr, addrType: ProtocolAddressType.Helper});
        protocolAddresses[12] = ProtocolAddressRow({
            name: "EXTERNAL__USDC", addr: usdcAddress.arbMainnetUSDC, addrType: ProtocolAddressType.External
        });
        protocolAddresses[13] =
            ProtocolAddressRow({name: "EXTERNAL__USDT", addr: USDT_ARBITRUM, addrType: ProtocolAddressType.External});
        protocolAddresses[14] = ProtocolAddressRow({
            name: "EXTERNAL__UNI_V3_POS_MANAGER",
            addr: UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARBITRUM,
            addrType: ProtocolAddressType.External
        });
        protocolAddresses[15] = ProtocolAddressRow({
            name: "EXTERNAL__UNI_UNIVERSAL_ROUTER", addr: UNIVERSAL_ROUTER, addrType: ProtocolAddressType.External
        });
        protocolAddresses[16] = ProtocolAddressRow({
            name: "EXTERNAL__UNI_PERMIT_2", addr: UNI_PERMIT2_ARBITRUM, addrType: ProtocolAddressType.External
        });

        _writeAddressManagerCsv(block.chainid, addressManager, protocolAddresses, "AddressManager.csv");

        return (
            addressManagerAddr,
            sfVaultAddr,
            sfStrategyAggregatorAddr,
            sfUniswapV3StrategyAddr,
            uniswapV3MathHelperAddr,
            sfTwapValuatorAddr,
            sfVaultLensAddr,
            sfStrategyAggregatorLensAddr,
            sfUniswapV3StrategyLensAddr,
            sfLensAddr
        );
    }
}

/*
Pending calls in the operator multisig after deployment:
vault.setERC721ApprovalForAll({nft: UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARBITRUM, operator: uniV3Strategy, approved: true});
vault.whitelistToken(usdt);
sfTwapValuator.setValuationPool(usdt, POOL);
sfTwapValuator.setTwapWindow(1800);
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
addressManager.owner() == 0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F
*/
