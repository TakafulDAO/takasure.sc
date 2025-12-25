// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, stdJson} from "forge-std/Script.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {UniswapV3MathHelper} from "contracts/helpers/uniswapHelpers/UniswapV3MathHelper.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

contract DeploySFUniV3Strategy is Script, DeployConstants {
    function run(IAddressManager addressManager, address vault) external returns (SFUniswapV3Strategy sfUniV3Strategy) {
        vm.startBroadcast(msg.sender);

        UniswapV3MathHelper uniswapV3MathHelper = new UniswapV3MathHelper();

        // Deploy SFUniswapV3Strategy
        address sfUniV3StrategyImplementation = address(new SFUniswapV3Strategy());

        /**
         * Will be using the USDC/USDT pool at 0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6.
         * This is a 0.01% fee tier pool on arbitrum with a tick spacing of 1
         * any tick will work -500 to 500 good for testing, never out of range
         * -200 to 200 also good will be the more realistic range
         * As the price is P=1.0001**tick, then this is prices from 0.980 to 1.020
         */
        address sfUniV3StrategyAddress = UnsafeUpgrades.deployUUPSProxy(
            sfUniV3StrategyImplementation,
            abi.encodeCall(
                SFUniswapV3Strategy.initialize,
                (
                    addressManager,
                    vault,
                    IERC20(usdcAddress.arbMainnetUSDC), // underlying
                    IERC20(0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9), // USDT
                    0xbE3aD6a5669Dc0B8b12FeBC03608860C31E2eef6, // USDC/USDT pool. This is a 0.01% fee tier pool on arbitrum with a tick spacing of 1
                    UNI_V3_NON_FUNGIBLE_POSITION_MANAGER_ARBITRUM,
                    address(uniswapV3MathHelper),
                    100000e6, // max tvl
                    UNIVERSAL_ROUTER,
                    -200,
                    200
                )
            )
        );

        sfUniV3Strategy = SFUniswapV3Strategy(sfUniV3StrategyAddress);
        vm.stopBroadcast();

        return (sfUniV3Strategy);
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
