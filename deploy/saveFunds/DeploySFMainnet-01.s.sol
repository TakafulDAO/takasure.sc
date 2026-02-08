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
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {DeploymentArtifacts} from "deploy/utils/DeploymentArtifacts.s.sol";

contract DeploySFMainnet is DeploymentArtifacts {
    struct DeploymentState {
        address addressManager;
        address sfVault;
        address sfStrategyAggregator;
        address sfUniswapV3Strategy;
        address uniswapV3MathHelper;
        address sfTwapValuator;
        address sfVaultLens;
        address sfStrategyAggregatorLens;
        address sfUniswapV3StrategyLens;
        address sfLens;
    }

    address constant OPERATOR_MULTISIG = 0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F;
    address constant BACKEND = 0x38Ea1c9243962E52ACf92CE4b4bB84879792BCbe;
    address constant FEE_RECEIVER_MULTISIG = 0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F; // TODO: Change this one
    address constant POOL = 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6;

    uint256 constant MAX_TVL = 20_000e6;
    function run()
        external
        returns (
            address,
            address,
            address,
            address,
            address,
            address,
            address,
            address,
            address,
            address
        )
    {
        vm.startBroadcast();

        // Deploy AddressManager
        DeploymentState memory state;
        state.addressManager =
            Upgrades.deployUUPSProxy("AddressManager.sol", abi.encodeCall(AddressManager.initialize, (msg.sender)));

        AddressManager addressManager = AddressManager(state.addressManager);
        console2.log("AddressManager deployed at:", state.addressManager);

        // Deploy SFVault
        state.sfVault = Upgrades.deployUUPSProxy(
            "SFVault.sol",
            abi.encodeCall(
                SFVault.initialize,
                (IAddressManager(state.addressManager), IERC20(usdcAddress.arbMainnetUSDC), "TLDSaveVault", "TLDSV")
            )
        );
        console2.log("SFVault deployed at:", state.sfVault);

        // Deploy SFStrategyAggregator
        state.sfStrategyAggregator = Upgrades.deployUUPSProxy(
            "SFStrategyAggregator.sol",
            abi.encodeCall(
                SFStrategyAggregator.initialize,
                (IAddressManager(state.addressManager), IERC20(usdcAddress.arbMainnetUSDC))
            )
        );
        console2.log("SFStrategyAggregator deployed at:", state.sfStrategyAggregator);

        // Deploy SFTwapValuator
        state.sfTwapValuator = address(new SFTwapValuator(IAddressManager(state.addressManager), 1800));
        console2.log("SFTwapValuator deployed at:", state.sfTwapValuator);

        // Deploy UniswapV3MathHelper
        state.uniswapV3MathHelper = address(new UniswapV3MathHelper());

        (, int24 currentTick,,,,,) = IUniswapV3Pool(POOL).slot0();
        int24 tickLower = currentTick - int24(3);
        int24 tickUpper = currentTick + int24(2);
        console2.log("currentTick:", currentTick);
        console2.log("tickLower:", tickLower);
        console2.log("tickUpper:", tickUpper);

        // Deploy SFUniswapV3Strategy
        state.sfUniswapV3Strategy = _deployUniV3Strategy(
            state.addressManager, state.sfVault, state.uniswapV3MathHelper, tickLower, tickUpper
        );
        console2.log("SFUniswapV3Strategy deployed at:", state.sfUniswapV3Strategy);

        // Deploy lens contracts
        state.sfVaultLens = address(new SFVaultLens());
        state.sfStrategyAggregatorLens = address(new SFStrategyAggregatorLens());
        state.sfUniswapV3StrategyLens = address(new SFUniswapV3StrategyLens());
        state.sfLens =
            address(new SFLens(state.sfVaultLens, state.sfStrategyAggregatorLens, state.sfUniswapV3StrategyLens));

        console2.log("SFVaultLens deployed at:", state.sfVaultLens);
        console2.log("SFStrategyAggregatorLens deployed at:", state.sfStrategyAggregatorLens);
        console2.log("SFUniswapV3StrategyLens deployed at:", state.sfUniswapV3StrategyLens);
        console2.log("SFLens deployed at:", state.sfLens);

        // Creating roles in AddressManager
        addressManager.createNewRole(Roles.OPERATOR);
        addressManager.createNewRole(Roles.PAUSE_GUARDIAN);
        addressManager.createNewRole(Roles.BACKEND_ADMIN);
        addressManager.createNewRole(Roles.KEEPER);
        console2.log("Roles created in AddressManager");

        // Propose operator to msg.sender and accept it so we can do operator actions in this script
        addressManager.proposeRoleHolder(Roles.OPERATOR, msg.sender);
        addressManager.acceptProposedRole(Roles.OPERATOR);

        // Propose initial role holders
        // The operator multisig will hold multiple roles after accepting
        addressManager.proposeRoleHolder(Roles.PAUSE_GUARDIAN, OPERATOR_MULTISIG);
        addressManager.proposeRoleHolder(Roles.KEEPER, OPERATOR_MULTISIG);
        addressManager.proposeRoleHolder(Roles.BACKEND_ADMIN, BACKEND);
        console2.log("Initial role holders proposed in AddressManager");

        // Add addresses
        addressManager.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", FEE_RECEIVER_MULTISIG, ProtocolAddressType.Admin);
        addressManager.addProtocolAddress("ADMIN__OPERATOR", OPERATOR_MULTISIG, ProtocolAddressType.Admin);
        addressManager.addProtocolAddress("ADMIN__BACKEND_ADMIN", BACKEND, ProtocolAddressType.Admin);
        addressManager.addProtocolAddress("PROTOCOL__SF_VAULT", state.sfVault, ProtocolAddressType.Protocol);
        addressManager.addProtocolAddress(
            "PROTOCOL__SF_AGGREGATOR", state.sfStrategyAggregator, ProtocolAddressType.Protocol
        );
        addressManager.addProtocolAddress(
            "PROTOCOL__SF_UNISWAP_V3_STRATEGY", state.sfUniswapV3Strategy, ProtocolAddressType.Protocol
        );
        addressManager.addProtocolAddress(
            "HELPER__UNISWAP_V3_MATH_HELPER", state.uniswapV3MathHelper, ProtocolAddressType.Helper
        );
        addressManager.addProtocolAddress("HELPER__SF_VALUATOR", state.sfTwapValuator, ProtocolAddressType.Helper);
        addressManager.addProtocolAddress("HELPER__SF_VAULT_LENS", state.sfVaultLens, ProtocolAddressType.Helper);
        addressManager.addProtocolAddress(
            "HELPER__SF_STRATEGY_AGG_LENS", state.sfStrategyAggregatorLens, ProtocolAddressType.Helper
        );
        addressManager.addProtocolAddress(
            "HELPER__SF_UNIV3_STRAT_LENS", state.sfUniswapV3StrategyLens, ProtocolAddressType.Helper
        );
        addressManager.addProtocolAddress("HELPER__SF_LENS", state.sfLens, ProtocolAddressType.Helper);

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

        // Operator actions
        SFVault(state.sfVault).setERC721ApprovalForAll(
            UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARBITRUM, state.sfUniswapV3Strategy, true
        );
        SFVault(state.sfVault).whitelistToken(USDT_ARBITRUM);
        SFTwapValuator(state.sfTwapValuator).setValuationPool(USDT_ARBITRUM, POOL);
        SFTwapValuator(state.sfTwapValuator).setTwapWindow(1800);
        SFStrategyAggregator(state.sfStrategyAggregator).addSubStrategy(state.sfUniswapV3Strategy, 10_000);
        _setDefaultWithdrawPayload(state.sfStrategyAggregator, state.sfUniswapV3Strategy);

        // Propose new operator before transferring ownership
        addressManager.proposeRoleHolder(Roles.OPERATOR, OPERATOR_MULTISIG);

        // Transfer Ownership to Operator Multisig
        addressManager.transferOwnership(OPERATOR_MULTISIG);
        console2.log("AddressManager ownership transferred to:", OPERATOR_MULTISIG);

        vm.stopBroadcast();

        _writeArtifacts(state);

        return (
            state.addressManager,
            state.sfVault,
            state.sfStrategyAggregator,
            state.sfUniswapV3Strategy,
            state.uniswapV3MathHelper,
            state.sfTwapValuator,
            state.sfVaultLens,
            state.sfStrategyAggregatorLens,
            state.sfUniswapV3StrategyLens,
            state.sfLens
        );
    }

    function _deployUniV3Strategy(
        address addressManagerAddr,
        address sfVaultAddr,
        address uniswapV3MathHelperAddr,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (address) {
        return Upgrades.deployUUPSProxy(
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
                    tickLower,
                    tickUpper
                )
            )
        );
    }

    function _setDefaultWithdrawPayload(address sfStrategyAggregatorAddr, address sfUniswapV3StrategyAddr)
        internal
    {
        uint256 amountInBpsFlag = (uint256(1) << 255) | 10_000; // swap 100% of balance
        uint24 poolFee = IUniswapV3Pool(POOL).fee();
        bytes memory path = abi.encodePacked(USDT_ARBITRUM, poolFee, usdcAddress.arbMainnetUSDC);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(sfUniswapV3StrategyAddr, amountInBpsFlag, uint256(0), path, true);

        bytes memory swapToUnderlyingData = abi.encode(inputs, uint256(0)); // deadline sentinel
        bytes memory defaultWithdrawPayload =
            abi.encode(uint16(0), bytes(""), swapToUnderlyingData, uint256(0), uint256(0), uint256(0));

        SFStrategyAggregator(sfStrategyAggregatorAddr).setDefaultWithdrawPayload(
            sfUniswapV3StrategyAddr, defaultWithdrawPayload
        );
    }

    function _writeArtifacts(DeploymentState memory state) internal {
        DeploymentItem[] memory deployments = new DeploymentItem[](10);
        deployments[0] = DeploymentItem({name: "AddressManager", addr: state.addressManager});
        deployments[1] = DeploymentItem({name: "SFVault", addr: state.sfVault});
        deployments[2] = DeploymentItem({name: "SFStrategyAggregator", addr: state.sfStrategyAggregator});
        deployments[3] = DeploymentItem({name: "SFUniswapV3Strategy", addr: state.sfUniswapV3Strategy});
        deployments[4] = DeploymentItem({name: "UniswapV3MathHelper", addr: state.uniswapV3MathHelper});
        deployments[5] = DeploymentItem({name: "SFTwapValuator", addr: state.sfTwapValuator});
        deployments[6] = DeploymentItem({name: "SFVaultLens", addr: state.sfVaultLens});
        deployments[7] = DeploymentItem({name: "SFStrategyAggregatorLens", addr: state.sfStrategyAggregatorLens});
        deployments[8] = DeploymentItem({name: "SFUniswapV3StrategyLens", addr: state.sfUniswapV3StrategyLens});
        deployments[9] = DeploymentItem({name: "SFLens", addr: state.sfLens});

        _writeDeployments(block.chainid, deployments);

        ProtocolAddressRow[] memory protocolAddresses = new ProtocolAddressRow[](17);
        protocolAddresses[0] = ProtocolAddressRow({
            name: "ADMIN__SF_FEE_RECEIVER", addr: FEE_RECEIVER_MULTISIG, addrType: ProtocolAddressType.Admin
        });
        protocolAddresses[1] =
            ProtocolAddressRow({name: "ADMIN__OPERATOR", addr: OPERATOR_MULTISIG, addrType: ProtocolAddressType.Admin});
        protocolAddresses[2] =
            ProtocolAddressRow({name: "ADMIN__BACKEND_ADMIN", addr: BACKEND, addrType: ProtocolAddressType.Admin});
        protocolAddresses[3] =
            ProtocolAddressRow({name: "PROTOCOL__SF_VAULT", addr: state.sfVault, addrType: ProtocolAddressType.Protocol});
        protocolAddresses[4] = ProtocolAddressRow({
            name: "PROTOCOL__SF_AGGREGATOR",
            addr: state.sfStrategyAggregator,
            addrType: ProtocolAddressType.Protocol
        });
        protocolAddresses[5] = ProtocolAddressRow({
            name: "PROTOCOL__SF_UNISWAP_V3_STRATEGY",
            addr: state.sfUniswapV3Strategy,
            addrType: ProtocolAddressType.Protocol
        });
        protocolAddresses[6] = ProtocolAddressRow({
            name: "HELPER__UNISWAP_V3_MATH_HELPER", addr: state.uniswapV3MathHelper, addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[7] = ProtocolAddressRow({
            name: "HELPER__SF_VALUATOR", addr: state.sfTwapValuator, addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[8] = ProtocolAddressRow({
            name: "HELPER__SF_VAULT_LENS", addr: state.sfVaultLens, addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[9] = ProtocolAddressRow({
            name: "HELPER__SF_STRATEGY_AGG_LENS",
            addr: state.sfStrategyAggregatorLens,
            addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[10] = ProtocolAddressRow({
            name: "HELPER__SF_UNIV3_STRAT_LENS",
            addr: state.sfUniswapV3StrategyLens,
            addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[11] =
            ProtocolAddressRow({name: "HELPER__SF_LENS", addr: state.sfLens, addrType: ProtocolAddressType.Helper});
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

        _writeAddressManagerCsv(
            block.chainid,
            AddressManager(state.addressManager),
            protocolAddresses,
            "AddressManager.csv"
        );
    }
}

/*
Pending calls in the operator multisig after deployment:
addressManager.acceptOwnership();
addressManager.acceptProposedRole(Roles.OPERATOR);
addressManager.acceptProposedRole(Roles.PAUSE_GUARDIAN);
addressManager.acceptProposedRole(Roles.KEEPER);
addressManager.acceptProposedRole(Roles.BACKEND_ADMIN);

Checks
vault.isTokenWhitelisted(usdt) == true
vault.isTokenWhitelisted(usdc) == true
IERC721(UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARBITRUM).isApprovedForAll(vault, uniV3Strategy) == true
sfTwapValuator.valuationPool(usdt) == POOL
sfTwapValuator.twapWindow() == 1800
aggregator.getSubStrategies()
aggregator.getSubStrategies().length == 1
address(aggregator.getSubStrategies()[0].strategy) == uniV3Strategy
aggregator.getSubStrategies()[0].targetWeightBPS == 100
aggregator.getSubStrategies()[0].isActive == true
aggregator.getDefaultWithdrawPayload(uniV3Strategy).length > 0
addressManager.getProtocolAddressByName("PROTOCOL__SF_VAULT").addr == sfVault
addressManager.currentRoleHolders(Roles.OPERATOR) == OPERATOR_MULTISIG
addressManager.hasRole(Roles.OPERATOR, OPERATOR_MULTISIG) == true
addressManager.owner() == 0x3F2bdF387e75C9896F94C6BA1aC36754425aCf5F
*/
