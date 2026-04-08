// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Options} from "openzeppelin-foundry-upgrades/Defender.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DeploymentArtifacts} from "deploy/utils/DeploymentArtifacts.s.sol";
import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/protocol/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {SFUniswapV3SwapRouterHelper} from "contracts/helpers/uniswapHelpers/SFUniswapV3SwapRouterHelper.sol";
import {UniswapV4Swap} from "contracts/helpers/uniswapHelpers/libraries/UniswapV4Swap.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract UniV4SwapRoutesUpgrade is Script, DeploymentArtifacts, GetContractAddress {
    error UniV4SwapRoutesUpgrade__UnsupportedChainId(uint256 chainId);
    error UniV4SwapRoutesUpgrade__CallerMustBeOperator(address caller);
    error UniV4SwapRoutesUpgrade__CallerMustOwnAddressManager(address caller, address owner);

    string internal constant SWAP_ROUTER_HELPER_NAME = "HELPER__SF_SWAP_ROUTER";
    uint8 internal constant ROUTE_V3_SINGLE_HOP = 1;
    uint8 internal constant ROUTE_V4_SINGLE_HOP = 2;
    uint16 internal constant MAX_BPS = 10_000;
    uint256 internal constant AMOUNT_IN_BPS_FLAG = uint256(1) << 255;

    bytes32 internal constant TARGET_SWAP_V4_POOL_ID =
        0xab05003a63d2f34ac7eec4670bca3319f0e3d2f62af5c2b9cbd69d03fd804fd2;
    uint24 internal constant TARGET_SWAP_V4_POOL_FEE = 8;
    int24 internal constant TARGET_SWAP_V4_POOL_TICK_SPACING = 1;
    address internal constant TARGET_SWAP_V4_POOL_HOOKS = address(0);

    struct UpgradeAddresses {
        address addressManager;
        address aggregator;
        address uniV3Strategy;
    }

    struct PreparedImplementations {
        address aggregatorImplementation;
        address uniV3StrategyImplementation;
    }

    function run() external returns (address helper_) {
        if (block.chainid == ARB_SEPOLIA_CHAIN_ID) return _runTestnet();
        if (block.chainid == ARB_MAINNET_CHAIN_ID) return _runMainnet();

        revert UniV4SwapRoutesUpgrade__UnsupportedChainId(block.chainid);
    }

    function _runTestnet() internal returns (address helper_) {
        UpgradeAddresses memory a = _resolveAddresses(block.chainid);
        AddressManager addressManager = AddressManager(a.addressManager);

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        _checkPermissions(addressManager, deployer);

        helper_ = address(new SFUniswapV3SwapRouterHelper(a.addressManager));
        _upsertSwapRouterHelper(addressManager, helper_);

        Upgrades.upgradeProxy(a.aggregator, "SFStrategyAggregator.sol", "");
        Upgrades.upgradeProxy(a.uniV3Strategy, "SFUniswapV3Strategy.sol", "");

        SFUniswapV3Strategy strategy = SFUniswapV3Strategy(a.uniV3Strategy);
        SFStrategyAggregator aggregator = SFStrategyAggregator(a.aggregator);
        bytes memory defaultWithdrawPayload = _buildDefaultWithdrawPayload();

        strategy.setSwapV4PoolConfig(
            TARGET_SWAP_V4_POOL_FEE, TARGET_SWAP_V4_POOL_TICK_SPACING, TARGET_SWAP_V4_POOL_HOOKS
        );
        aggregator.setDefaultWithdrawPayload(a.uniV3Strategy, defaultWithdrawPayload);

        vm.stopBroadcast();

        _writeDeploymentJson(block.chainid, "SFUniswapV3SwapRouterHelper", helper_);
        _verifyTestnetPostUpgrade(addressManager, aggregator, strategy, helper_, defaultWithdrawPayload);
        _logResolvedAddresses(a, helper_);
    }

    function _runMainnet() internal returns (address helper_) {
        UpgradeAddresses memory a = _resolveAddresses(block.chainid);
        PreparedImplementations memory prepared_;
        Options memory opts;

        Upgrades.validateUpgrade("SFStrategyAggregator.sol", opts);
        console2.log("SFStrategyAggregator.sol is upgradeable");

        Upgrades.validateUpgrade("SFUniswapV3Strategy.sol", opts);
        console2.log("SFUniswapV3Strategy.sol is upgradeable");

        vm.startBroadcast();

        helper_ = address(new SFUniswapV3SwapRouterHelper(a.addressManager));
        prepared_.aggregatorImplementation = address(new SFStrategyAggregator());
        prepared_.uniV3StrategyImplementation = address(new SFUniswapV3Strategy());

        vm.stopBroadcast();

        _writeDeploymentJson(block.chainid, "SFUniswapV3SwapRouterHelper", helper_);
        _logResolvedAddresses(a, helper_);
        _logMainnetPreparedImplementations(prepared_);
        _logMainnetPendingCalls(a, helper_, prepared_, _buildDefaultWithdrawPayload());
    }

    function _resolveAddresses(uint256 chainId) internal view returns (UpgradeAddresses memory a_) {
        a_.addressManager = _getContractAddress(chainId, "AddressManager");
        a_.aggregator = _getContractAddress(chainId, "SFStrategyAggregator");
        a_.uniV3Strategy = _getContractAddress(chainId, "SFUniswapV3Strategy");
    }

    function _checkPermissions(AddressManager addressManager, address deployer) internal view {
        if (!addressManager.hasRole(Roles.OPERATOR, deployer)) {
            revert UniV4SwapRoutesUpgrade__CallerMustBeOperator(deployer);
        }

        address owner = addressManager.owner();
        if (owner != deployer) {
            revert UniV4SwapRoutesUpgrade__CallerMustOwnAddressManager(deployer, owner);
        }
    }

    function _upsertSwapRouterHelper(AddressManager addressManager, address helper) internal {
        try addressManager.updateProtocolAddress(SWAP_ROUTER_HELPER_NAME, helper) {}
        catch {
            addressManager.addProtocolAddress(SWAP_ROUTER_HELPER_NAME, helper, ProtocolAddressType.Helper);
        }
    }

    function _buildDefaultWithdrawPayload() internal pure returns (bytes memory payload_) {
        uint8[2] memory routeIds;
        uint256[2] memory amountOutMins;
        routeIds[0] = ROUTE_V3_SINGLE_HOP;
        routeIds[1] = ROUTE_V4_SINGLE_HOP;

        bytes memory swapToUnderlyingData = abi.encode(
            AMOUNT_IN_BPS_FLAG | uint256(MAX_BPS),
            uint256(0), // deadline sentinel
            uint8(2),
            routeIds,
            amountOutMins
        );

        payload_ = abi.encode(uint16(0), bytes(""), swapToUnderlyingData, uint256(0), uint256(0), uint256(0));
    }

    function _verifyTestnetPostUpgrade(
        AddressManager addressManager,
        SFStrategyAggregator aggregator,
        SFUniswapV3Strategy strategy,
        address helper,
        bytes memory defaultWithdrawPayload
    ) internal view {
        require(addressManager.getProtocolAddressByName(SWAP_ROUTER_HELPER_NAME).addr == helper, "Unexpected helper");

        bytes32 packedConfigSlot = vm.load(helper, bytes32(uint256(0)));
        bytes32 hooksSlot = vm.load(helper, bytes32(uint256(1)));
        uint24 storedFee = uint24(uint256(packedConfigSlot));
        int24 storedTickSpacing = int24(uint24(uint256(packedConfigSlot >> 24)));
        address storedHooks = address(uint160(uint256(hooksSlot)));

        require(_expectedSwapPoolId(strategy) == TARGET_SWAP_V4_POOL_ID, "Unexpected V4 swap pool id");
        require(storedFee == TARGET_SWAP_V4_POOL_FEE, "Unexpected swap fee");
        require(storedTickSpacing == TARGET_SWAP_V4_POOL_TICK_SPACING, "Unexpected tick spacing");
        require(storedHooks == TARGET_SWAP_V4_POOL_HOOKS, "Unexpected hooks");
        require(
            keccak256(aggregator.getDefaultWithdrawPayload(address(strategy))) == keccak256(defaultWithdrawPayload),
            "Unexpected default withdraw payload"
        );

        console2.logBytes32(_expectedSwapPoolId(strategy));
        console2.log("Configured swap V4 fee:", storedFee);
        console2.log("Configured swap V4 tick spacing:", storedTickSpacing);
        console2.log("Configured swap V4 hooks:", storedHooks);
    }

    function _expectedSwapPoolId(SFUniswapV3Strategy strategy) internal view returns (bytes32 poolId_) {
        address poolAddress = address(strategy.pool());
        address token0 = IUniswapV3Pool(poolAddress).token0();
        address token1 = IUniswapV3Pool(poolAddress).token1();
        UniswapV4Swap.PoolKey memory swapPoolKey = UniswapV4Swap.buildPoolKey(
            token0, token1, TARGET_SWAP_V4_POOL_FEE, TARGET_SWAP_V4_POOL_TICK_SPACING, TARGET_SWAP_V4_POOL_HOOKS
        );
        poolId_ = UniswapV4Swap.computePoolId(swapPoolKey);
    }

    function _logResolvedAddresses(UpgradeAddresses memory a, address helper) internal view {
        console2.log("AddressManager:", a.addressManager);
        console2.log("SFStrategyAggregator:", a.aggregator);
        console2.log("SFUniswapV3Strategy:", a.uniV3Strategy);
        console2.log("SFUniswapV3SwapRouterHelper:", helper);
    }

    function _logMainnetPreparedImplementations(PreparedImplementations memory prepared_) internal view {
        console2.log("Prepared SFStrategyAggregator implementation:", prepared_.aggregatorImplementation);
        console2.log("Prepared SFUniswapV3Strategy implementation:", prepared_.uniV3StrategyImplementation);
    }

    function _logMainnetPendingCalls(
        UpgradeAddresses memory a,
        address helper,
        PreparedImplementations memory prepared_,
        bytes memory defaultWithdrawPayload
    ) internal view {
        bytes32 expectedPoolId = _expectedSwapPoolId(SFUniswapV3Strategy(a.uniV3Strategy));
        require(expectedPoolId == TARGET_SWAP_V4_POOL_ID, "Unexpected V4 swap pool id");

        console2.log("Expected swap pool id:");
        console2.logBytes32(expectedPoolId);
        console2.log("=============================");
        console2.log("Pending multisig action 1:");
        console2.log("AddressManager.addProtocolAddress(HELPER__SF_SWAP_ROUTER, helper, ProtocolAddressType.Helper)");
        console2.logAddress(helper);
        console2.log("=============================");
        console2.log("Pending multisig action 2:");
        console2.log("SFStrategyAggregator.upgradeToAndCall(newImplementation, bytes(\\\"\\\"))");
        console2.logAddress(prepared_.aggregatorImplementation);
        console2.log("=============================");
        console2.log("Pending multisig action 3:");
        console2.log("SFUniswapV3Strategy.upgradeToAndCall(newImplementation, bytes(\\\"\\\"))");
        console2.logAddress(prepared_.uniV3StrategyImplementation);
        console2.log("=============================");
        console2.log("Pending multisig action 4:");
        console2.log("SFUniswapV3Strategy.setSwapV4PoolConfig(8, 1, address(0))");
        console2.log("=============================");
        console2.log("Pending multisig action 5:");
        console2.log("SFStrategyAggregator.setDefaultWithdrawPayload(strategy, payload)");
        console2.log("Default withdraw payload:");
        console2.log("");
        console2.logBytes(defaultWithdrawPayload);
        console2.log("=============================");
    }
}

/*
Mainnet pending multisig calls after running this script:
1. AddressManager.addProtocolAddress("HELPER__SF_SWAP_ROUTER", helper, ProtocolAddressType.Helper)
2. SFStrategyAggregator(aggregatorProxy).upgradeToAndCall(newAggregatorImplementation, "")
3. SFUniswapV3Strategy(strategyProxy).upgradeToAndCall(newStrategyImplementation, "")
4. SFUniswapV3Strategy(strategyProxy).setSwapV4PoolConfig(8, 1, address(0))
5. SFStrategyAggregator(aggregatorProxy).setDefaultWithdrawPayload(strategyProxy, defaultWithdrawPayload)
*/
