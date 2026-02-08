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
import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";

contract DeploySF is DeploymentArtifacts, GetContractAddress {
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

    struct DeployConfig {
        address operator;
        address feeReceiver;
        address pauseGuardian;
        address backendAdmin;
        address pool;
        address usdc;
        address usdt;
        address uniV3PositionManager;
        address universalRouter;
        address addressManager;
        address uniswapV3MathHelper;
        int24 tickLowerDelta;
        int24 tickUpperDelta;
    }

    function run() external {
        console2.log("Starting SaveFunds deployment...");
        uint256 chainId = block.chainid;
        DeployConfig memory cfg = _getDeployConfig(chainId);

        vm.startBroadcast();

        // Deploy AddressManager
        DeploymentState memory state;
        if (cfg.addressManager == address(0)) {
            state.addressManager =
                Upgrades.deployUUPSProxy("AddressManager.sol", abi.encodeCall(AddressManager.initialize, (msg.sender)));
            console2.log("AddressManager deployed at:", state.addressManager);
        } else {
            state.addressManager = cfg.addressManager;
            console2.log("AddressManager reused at:", state.addressManager);
        }

        AddressManager addressManager = AddressManager(state.addressManager);

        // Deploy SFVault
        state.sfVault = Upgrades.deployUUPSProxy(
            "SFVault.sol",
            abi.encodeCall(
                SFVault.initialize, (IAddressManager(state.addressManager), IERC20(cfg.usdc), "TLDSaveVault", "TLDSV")
            )
        );
        console2.log("SFVault deployed at:", state.sfVault);

        // Deploy SFStrategyAggregator
        state.sfStrategyAggregator = Upgrades.deployUUPSProxy(
            "SFStrategyAggregator.sol",
            abi.encodeCall(SFStrategyAggregator.initialize, (IAddressManager(state.addressManager), IERC20(cfg.usdc)))
        );
        console2.log("SFStrategyAggregator deployed at:", state.sfStrategyAggregator);

        // Deploy SFTwapValuator
        state.sfTwapValuator = address(new SFTwapValuator(IAddressManager(state.addressManager), 1800));
        console2.log("SFTwapValuator deployed at:", state.sfTwapValuator);

        // Deploy UniswapV3MathHelper
        if (cfg.uniswapV3MathHelper == address(0)) {
            state.uniswapV3MathHelper = address(new UniswapV3MathHelper());
            console2.log("UniswapV3MathHelper deployed at:", state.uniswapV3MathHelper);
        } else {
            state.uniswapV3MathHelper = cfg.uniswapV3MathHelper;
            console2.log("UniswapV3MathHelper reused at:", state.uniswapV3MathHelper);
        }

        // Creating roles in AddressManager
        if (!addressManager.isValidRole(Roles.OPERATOR)) addressManager.createNewRole(Roles.OPERATOR);
        if (!addressManager.isValidRole(Roles.PAUSE_GUARDIAN)) addressManager.createNewRole(Roles.PAUSE_GUARDIAN);
        if (!addressManager.isValidRole(Roles.BACKEND_ADMIN)) addressManager.createNewRole(Roles.BACKEND_ADMIN);
        if (!addressManager.isValidRole(Roles.KEEPER)) addressManager.createNewRole(Roles.KEEPER);
        console2.log("Roles created in AddressManager");

        // Propose operator to msg.sender and accept it so we can do operator actions in this script
        if (!addressManager.hasRole(Roles.OPERATOR, msg.sender)) {
            addressManager.proposeRoleHolder(Roles.OPERATOR, msg.sender);
            addressManager.acceptProposedRole(Roles.OPERATOR);
        }

        // Whitelist USDT before deploying the strategy (it validates pool tokens on init)
        if (!SFVault(state.sfVault).isTokenWhitelisted(cfg.usdt)) {
            SFVault(state.sfVault).whitelistToken(cfg.usdt);
        }

        (, int24 currentTick,,,,,) = IUniswapV3Pool(cfg.pool).slot0();
        int24 tickLower = currentTick + cfg.tickLowerDelta;
        int24 tickUpper = currentTick + cfg.tickUpperDelta;
        int24 tickSpacing = IUniswapV3Pool(cfg.pool).tickSpacing();
        if (chainId == ARB_SEPOLIA_CHAIN_ID) {
            tickLower = _roundDownToSpacing(tickLower, tickSpacing);
            tickUpper = _roundDownToSpacing(tickUpper, tickSpacing);
            if (tickUpper <= tickLower) {
                tickUpper = tickLower + tickSpacing;
            }
        }
        console2.log("currentTick:", currentTick);
        console2.log("tickSpacing:", tickSpacing);
        console2.log("tickLower:", tickLower);
        console2.log("tickUpper:", tickUpper);

        // Deploy SFUniswapV3Strategy
        state.sfUniswapV3Strategy = _deployUniV3Strategy(state, cfg, tickLower, tickUpper);
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

        // Propose initial role holders
        // The operator multisig will hold multiple roles after accepting
        addressManager.proposeRoleHolder(Roles.PAUSE_GUARDIAN, cfg.pauseGuardian);
        addressManager.proposeRoleHolder(Roles.KEEPER, cfg.operator);
        addressManager.proposeRoleHolder(Roles.BACKEND_ADMIN, cfg.backendAdmin);
        console2.log("Initial role holders proposed in AddressManager");

        // Add addresses
        addressManager.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", cfg.feeReceiver, ProtocolAddressType.Admin);
        addressManager.addProtocolAddress("ADMIN__OPERATOR", cfg.operator, ProtocolAddressType.Admin);
        addressManager.addProtocolAddress("ADMIN__BACKEND_ADMIN", cfg.backendAdmin, ProtocolAddressType.Admin);
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
        addressManager.addProtocolAddress("EXTERNAL__USDC", cfg.usdc, ProtocolAddressType.External);
        addressManager.addProtocolAddress("EXTERNAL__USDT", cfg.usdt, ProtocolAddressType.External);
        addressManager.addProtocolAddress(
            "EXTERNAL__UNI_V3_POS_MANAGER", cfg.uniV3PositionManager, ProtocolAddressType.External
        );
        addressManager.addProtocolAddress(
            "EXTERNAL__UNI_UNIVERSAL_ROUTER", cfg.universalRouter, ProtocolAddressType.External
        );
        addressManager.addProtocolAddress("EXTERNAL__UNI_PERMIT_2", UNI_PERMIT2_ARBITRUM, ProtocolAddressType.External);
        console2.log("Protocol addresses added in AddressManager");

        // Operator actions
        SFVault(state.sfVault).setERC721ApprovalForAll(cfg.uniV3PositionManager, state.sfUniswapV3Strategy, true);
        SFTwapValuator(state.sfTwapValuator).setValuationPool(cfg.usdt, cfg.pool);
        SFTwapValuator(state.sfTwapValuator).setTwapWindow(1800);
        SFStrategyAggregator(state.sfStrategyAggregator).addSubStrategy(state.sfUniswapV3Strategy, 10_000);
        _setDefaultWithdrawPayload(state.sfStrategyAggregator, state.sfUniswapV3Strategy, cfg.pool, cfg.usdt, cfg.usdc);

        // Propose new operator before transferring ownership
        addressManager.proposeRoleHolder(Roles.OPERATOR, cfg.operator);

        // Transfer Ownership to Operator Multisig
        addressManager.transferOwnership(cfg.operator);
        console2.log("AddressManager ownership transferred to:", cfg.operator);

        console2.log("SaveFunds deployment completed successfully!");

        vm.stopBroadcast();

        console2.log("Writing deployment artifacts...");

        _writeArtifacts(state, cfg, chainId);

        console2.log("Deployment artifacts written successfully!");
        console2.log("SaveFunds deployment script finished.");
    }

    function _getDeployConfig(uint256 _chainId) internal view returns (DeployConfig memory cfg_) {
        if (_chainId == ARB_MAINNET_CHAIN_ID) {
            cfg_.operator = SF_OPERATOR_ARB_ONE;
            cfg_.feeReceiver = SF_FEE_RECEIVER_ARB_ONE;
            cfg_.pauseGuardian = SF_PAUSE_GUARDIAN_ARB_ONE;
            cfg_.backendAdmin = SF_BACKEND_ADMIN_ARB_ONE;
            cfg_.pool = SF_UNI_POOL_ARB_ONE;
            cfg_.usdc = usdcAddress.arbMainnetUSDC;
            cfg_.usdt = USDT_ARBITRUM;
            cfg_.uniV3PositionManager = UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARBITRUM;
            cfg_.universalRouter = UNIVERSAL_ROUTER;
            cfg_.addressManager = address(0);
            cfg_.uniswapV3MathHelper = address(0);
            cfg_.tickLowerDelta = int24(-3);
            cfg_.tickUpperDelta = int24(2);
            return cfg_;
        }

        if (_chainId == ARB_SEPOLIA_CHAIN_ID) {
            cfg_.operator = SF_OPERATOR_ARB_SEPOLIA;
            cfg_.feeReceiver = SF_FEE_RECEIVER_ARB_SEPOLIA;
            cfg_.pauseGuardian = SF_PAUSE_GUARDIAN_ARB_SEPOLIA;
            cfg_.backendAdmin = SF_BACKEND_ADMIN_ARB_SEPOLIA;
            cfg_.pool = SF_UNI_POOL_ARB_SEPOLIA;
            cfg_.usdc = _getContractAddress(_chainId, "SFUSDC");
            cfg_.usdt = _getContractAddress(_chainId, "SFUSDT");
            cfg_.uniV3PositionManager = UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARB_SEPOLIA;
            cfg_.universalRouter = UNIVERSAL_ROUTER_ARB_SEPOLIA;
            cfg_.addressManager = _getContractAddress(_chainId, "AddressManager");
            cfg_.uniswapV3MathHelper = _getContractAddress(_chainId, "UniswapV3MathHelper");
            cfg_.tickLowerDelta = int24(-100);
            cfg_.tickUpperDelta = int24(100);
            return cfg_;
        }

        revert("Unsupported chainId");
    }

    function _deployUniV3Strategy(
        DeploymentState memory _state,
        DeployConfig memory _cfg,
        int24 _tickLower,
        int24 _tickUpper
    ) internal returns (address) {
        return Upgrades.deployUUPSProxy(
            "SFUniswapV3Strategy.sol",
            abi.encodeCall(
                SFUniswapV3Strategy.initialize,
                (
                    IAddressManager(_state.addressManager),
                    _state.sfVault,
                    IERC20(_cfg.usdc),
                    IERC20(_cfg.usdt),
                    _cfg.pool,
                    _cfg.uniV3PositionManager,
                    _state.uniswapV3MathHelper,
                    SF_MAX_TVL,
                    _cfg.universalRouter,
                    _tickLower,
                    _tickUpper
                )
            )
        );
    }

    function _setDefaultWithdrawPayload(
        address _sfStrategyAggregatorAddr,
        address _sfUniswapV3StrategyAddr,
        address _pool,
        address _usdt,
        address _usdc
    ) internal {
        uint256 _amountInBpsFlag = (uint256(1) << 255) | 10_000; // swap 100% of balance
        uint24 _poolFee = IUniswapV3Pool(_pool).fee();
        bytes memory _path = abi.encodePacked(_usdt, _poolFee, _usdc);

        bytes[] memory _inputs = new bytes[](1);
        _inputs[0] = abi.encode(_sfUniswapV3StrategyAddr, _amountInBpsFlag, uint256(0), _path, true);

        bytes memory _swapToUnderlyingData = abi.encode(_inputs, uint256(0)); // deadline sentinel
        bytes memory _defaultWithdrawPayload =
            abi.encode(uint16(0), bytes(""), _swapToUnderlyingData, uint256(0), uint256(0), uint256(0));

        SFStrategyAggregator(_sfStrategyAggregatorAddr)
            .setDefaultWithdrawPayload(_sfUniswapV3StrategyAddr, _defaultWithdrawPayload);
    }

    function _roundDownToSpacing(int24 _tick, int24 _spacing) internal pure returns (int24) {
        int24 remainder = _tick % _spacing;
        if (remainder == 0) return _tick;
        if (_tick < 0) {
            return _tick - (_spacing + remainder);
        }
        return _tick - remainder;
    }

    function _writeArtifacts(DeploymentState memory _state, DeployConfig memory _cfg, uint256 _chainId) internal {
        DeploymentItem[] memory _deployments = new DeploymentItem[](10);
        _deployments[0] = DeploymentItem({name: "AddressManager", addr: _state.addressManager});
        _deployments[1] = DeploymentItem({name: "SFVault", addr: _state.sfVault});
        _deployments[2] = DeploymentItem({name: "SFStrategyAggregator", addr: _state.sfStrategyAggregator});
        _deployments[3] = DeploymentItem({name: "SFUniswapV3Strategy", addr: _state.sfUniswapV3Strategy});
        _deployments[4] = DeploymentItem({name: "UniswapV3MathHelper", addr: _state.uniswapV3MathHelper});
        _deployments[5] = DeploymentItem({name: "SFTwapValuator", addr: _state.sfTwapValuator});
        _deployments[6] = DeploymentItem({name: "SFVaultLens", addr: _state.sfVaultLens});
        _deployments[7] = DeploymentItem({name: "SFStrategyAggregatorLens", addr: _state.sfStrategyAggregatorLens});
        _deployments[8] = DeploymentItem({name: "SFUniswapV3StrategyLens", addr: _state.sfUniswapV3StrategyLens});
        _deployments[9] = DeploymentItem({name: "SFLens", addr: _state.sfLens});

        _writeDeployments(_chainId, _deployments);

        ProtocolAddressRow[] memory protocolAddresses = new ProtocolAddressRow[](17);
        protocolAddresses[0] = ProtocolAddressRow({
            name: "ADMIN__SF_FEE_RECEIVER", addr: _cfg.feeReceiver, addrType: ProtocolAddressType.Admin
        });
        protocolAddresses[1] =
            ProtocolAddressRow({name: "ADMIN__OPERATOR", addr: _cfg.operator, addrType: ProtocolAddressType.Admin});
        protocolAddresses[2] = ProtocolAddressRow({
            name: "ADMIN__BACKEND_ADMIN", addr: _cfg.backendAdmin, addrType: ProtocolAddressType.Admin
        });
        protocolAddresses[3] = ProtocolAddressRow({
            name: "PROTOCOL__SF_VAULT", addr: _state.sfVault, addrType: ProtocolAddressType.Protocol
        });
        protocolAddresses[4] = ProtocolAddressRow({
            name: "PROTOCOL__SF_AGGREGATOR", addr: _state.sfStrategyAggregator, addrType: ProtocolAddressType.Protocol
        });
        protocolAddresses[5] = ProtocolAddressRow({
            name: "PROTOCOL__SF_UNISWAP_V3_STRATEGY",
            addr: _state.sfUniswapV3Strategy,
            addrType: ProtocolAddressType.Protocol
        });
        protocolAddresses[6] = ProtocolAddressRow({
            name: "HELPER__UNISWAP_V3_MATH_HELPER",
            addr: _state.uniswapV3MathHelper,
            addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[7] = ProtocolAddressRow({
            name: "HELPER__SF_VALUATOR", addr: _state.sfTwapValuator, addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[8] = ProtocolAddressRow({
            name: "HELPER__SF_VAULT_LENS", addr: _state.sfVaultLens, addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[9] = ProtocolAddressRow({
            name: "HELPER__SF_STRATEGY_AGG_LENS",
            addr: _state.sfStrategyAggregatorLens,
            addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[10] = ProtocolAddressRow({
            name: "HELPER__SF_UNIV3_STRAT_LENS",
            addr: _state.sfUniswapV3StrategyLens,
            addrType: ProtocolAddressType.Helper
        });
        protocolAddresses[11] =
            ProtocolAddressRow({name: "HELPER__SF_LENS", addr: _state.sfLens, addrType: ProtocolAddressType.Helper});
        protocolAddresses[12] =
            ProtocolAddressRow({name: "EXTERNAL__USDC", addr: _cfg.usdc, addrType: ProtocolAddressType.External});
        protocolAddresses[13] =
            ProtocolAddressRow({name: "EXTERNAL__USDT", addr: _cfg.usdt, addrType: ProtocolAddressType.External});
        protocolAddresses[14] = ProtocolAddressRow({
            name: "EXTERNAL__UNI_V3_POS_MANAGER",
            addr: _cfg.uniV3PositionManager,
            addrType: ProtocolAddressType.External
        });
        protocolAddresses[15] = ProtocolAddressRow({
            name: "EXTERNAL__UNI_UNIVERSAL_ROUTER", addr: _cfg.universalRouter, addrType: ProtocolAddressType.External
        });
        protocolAddresses[16] = ProtocolAddressRow({
            name: "EXTERNAL__UNI_PERMIT_2", addr: UNI_PERMIT2_ARBITRUM, addrType: ProtocolAddressType.External
        });

        string memory csvFileName = string.concat("AddressManager_", _chainName(_chainId), ".csv");
        _writeAddressManagerCsv(_chainId, AddressManager(_state.addressManager), protocolAddresses, csvFileName);
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
IERC721(positionManager).isApprovedForAll(vault, uniV3Strategy) == true
sfTwapValuator.valuationPool(usdt) == pool
sfTwapValuator.twapWindow() == 1800
aggregator.getSubStrategies()
aggregator.getSubStrategies().length == 1
address(aggregator.getSubStrategies()[0].strategy) == uniV3Strategy
aggregator.getSubStrategies()[0].targetWeightBPS == 100
aggregator.getSubStrategies()[0].isActive == true
aggregator.getDefaultWithdrawPayload(uniV3Strategy).length > 0
addressManager.getProtocolAddressByName("PROTOCOL__SF_VAULT").addr == sfVault
addressManager.currentRoleHolders(Roles.OPERATOR) == operator
addressManager.hasRole(Roles.OPERATOR, operator) == true
addressManager.owner() == operator
*/
