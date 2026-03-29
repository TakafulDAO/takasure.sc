// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {UniswapV4Swap} from "contracts/helpers/uniswapHelpers/libraries/UniswapV4Swap.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

contract UpgradeUniV3Strategy is Script, GetContractAddress {
    bytes32 internal constant TARGET_SWAP_V4_POOL_ID =
        0xab05003a63d2f34ac7eec4670bca3319f0e3d2f62af5c2b9cbd69d03fd804fd2;
    uint24 internal constant TARGET_SWAP_V4_POOL_FEE = 8;
    int24 internal constant TARGET_SWAP_V4_POOL_TICK_SPACING = 1;
    address internal constant TARGET_SWAP_V4_POOL_HOOKS = address(0);

    function run() external returns (address) {
        address sfUniswapV3StrategyAddress = _getContractAddress(block.chainid, "SFUniswapV3Strategy");
        address oldImplementation = Upgrades.getImplementationAddress(sfUniswapV3StrategyAddress);
        console2.log("Old SFUniswapV3Strategy implementation address: ", oldImplementation);

        vm.startBroadcast();

        // Upgrade SFUniswapV3Strategy
        Upgrades.upgradeProxy(sfUniswapV3StrategyAddress, "SFUniswapV3Strategy.sol", "");

        SFUniswapV3Strategy strategy = SFUniswapV3Strategy(sfUniswapV3StrategyAddress);
        strategy.setSwapV4PoolConfig(
            TARGET_SWAP_V4_POOL_FEE, TARGET_SWAP_V4_POOL_TICK_SPACING, TARGET_SWAP_V4_POOL_HOOKS
        );

        vm.stopBroadcast();

        address newImplementation = Upgrades.getImplementationAddress(sfUniswapV3StrategyAddress);
        console2.log("New SFUniswapV3Strategy implementation address: ", newImplementation);

        address poolAddress = address(strategy.pool());
        address token0 = IUniswapV3Pool(poolAddress).token0();
        address token1 = IUniswapV3Pool(poolAddress).token1();
        UniswapV4Swap.PoolKey memory swapPoolKey = UniswapV4Swap.buildPoolKey(
            token0, token1, TARGET_SWAP_V4_POOL_FEE, TARGET_SWAP_V4_POOL_TICK_SPACING, TARGET_SWAP_V4_POOL_HOOKS
        );
        bytes32 computedPoolId = UniswapV4Swap.computePoolId(swapPoolKey);
        bytes32 packedConfigSlot = vm.load(sfUniswapV3StrategyAddress, bytes32(uint256(13)));
        bytes32 hooksSlot = vm.load(sfUniswapV3StrategyAddress, bytes32(uint256(14)));
        uint24 storedFee = uint24(uint256(packedConfigSlot >> 96));
        int24 storedTickSpacing = int24(uint24(uint256(packedConfigSlot >> 120)));
        address storedHooks = address(uint160(uint256(hooksSlot)));

        require(computedPoolId == TARGET_SWAP_V4_POOL_ID, "Unexpected V4 swap pool id");
        require(storedFee == TARGET_SWAP_V4_POOL_FEE, "Unexpected swap fee");
        require(storedTickSpacing == TARGET_SWAP_V4_POOL_TICK_SPACING, "Unexpected tick spacing");
        require(storedHooks == TARGET_SWAP_V4_POOL_HOOKS, "Unexpected hooks");

        console2.logBytes32(computedPoolId);
        console2.log("Configured swap V4 fee:", storedFee);
        console2.log("Configured swap V4 tick spacing:", storedTickSpacing);
        console2.log("Configured swap V4 hooks:", storedHooks);

        return (newImplementation);
    }
}
