// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";

import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

contract UniV3RangeReplayForkTest is Test {
    struct TickRangeScenario {
        int24 lowerOffset;
        int24 upperOffset;
    }

    struct ScenarioSchedule {
        int24 initialLower;
        int24 initialUpper;
        uint256 rebalanceCount;
        uint256[6] blocks;
        int24[6] ticks;
        int24[6] newLowers;
        int24[6] newUppers;
    }

    uint256 internal constant FIRST_REBALANCE_BLOCK = 432300739;

    AddressGetter internal addrGetter;
    SFUniswapV3Strategy internal uniV3;
    IUniswapV3Pool internal pool;
    uint256 internal forkId;

    function setUp() public {
        // Start from the first historical rebalance checkpoint so every scenario shares
        // the same initial spot tick and the same deployed strategy/pool configuration.
        forkId = vm.createFork(vm.envString("ARBITRUM_MAINNET_RPC_URL"), FIRST_REBALANCE_BLOCK);
        vm.selectFork(forkId);

        addrGetter = new AddressGetter();
        uniV3 = SFUniswapV3Strategy(_getAddr("SFUniswapV3Strategy"));
        // The replay only needs the live pool because each checkpoint reuses the real
        // historical spot tick from slot0 rather than simulating a full rebalance.
        pool = IUniswapV3Pool(uniV3.pool());
    }

    function testForkHistorical_rangeScheduleAcrossHistoricalCheckpoints_CharacterizesLegacyRanges() public {
        // These are the alternative asymmetric/symmetric recentering policies to compare
        // against the same sequence of historical rebalance checkpoints.
        TickRangeScenario[5] memory scenarios = [
            TickRangeScenario({lowerOffset: -3, upperOffset: 3}), // Four times, instead of seven
            TickRangeScenario({lowerOffset: -3, upperOffset: 4}), // Three times, instead of seven
            TickRangeScenario({lowerOffset: -4, upperOffset: 4}), // Three times, instead of seven
            TickRangeScenario({lowerOffset: -4, upperOffset: 5}), // Three times, instead of seven
            TickRangeScenario({lowerOffset: -5, upperOffset: 5}) // Three times, instead of seven
        ];

        // Build an independent rebalance schedule for each policy using the same checkpoint list.
        ScenarioSchedule memory scenario1 = _buildSchedule(scenarios[0]);
        ScenarioSchedule memory scenario2 = _buildSchedule(scenarios[1]);
        ScenarioSchedule memory scenario3 = _buildSchedule(scenarios[2]);
        ScenarioSchedule memory scenario4 = _buildSchedule(scenarios[3]);
        ScenarioSchedule memory scenario5 = _buildSchedule(scenarios[4]);

        _logScenario("scenario 1", scenario1);
        _logScenario("scenario 2", scenario2);
        _logScenario("scenario 3", scenario3);
        _logScenario("scenario 4", scenario4);
        _logScenario("scenario 5", scenario5);

        assertEq(scenario1.initialLower, 0, "scenario 1 initial lower");
        assertEq(scenario1.initialUpper, 6, "scenario 1 initial upper");
        assertEq(scenario1.rebalanceCount, 3, "scenario 1 rebalance count");
        assertEq(scenario1.blocks[0], 438567069, "scenario 1 first rebalance block");
        assertEq(scenario1.blocks[1], 439991964, "scenario 1 second rebalance block");
        assertEq(scenario1.blocks[2], 446153834, "scenario 1 third rebalance block");

        assertEq(scenario2.initialLower, 0, "scenario 2 initial lower");
        assertEq(scenario2.initialUpper, 7, "scenario 2 initial upper");
        assertEq(scenario2.rebalanceCount, 2, "scenario 2 rebalance count");
        assertEq(scenario2.blocks[0], 438567069, "scenario 2 first rebalance block");
        assertEq(scenario2.blocks[1], 446153834, "scenario 2 second rebalance block");

        assertEq(scenario3.initialLower, -1, "scenario 3 initial lower");
        assertEq(scenario3.initialUpper, 7, "scenario 3 initial upper");
        assertEq(scenario3.rebalanceCount, 2, "scenario 3 rebalance count");
        assertEq(scenario3.blocks[0], 438567069, "scenario 3 first rebalance block");
        assertEq(scenario3.blocks[1], 446153834, "scenario 3 second rebalance block");

        assertEq(scenario4.initialLower, -1, "scenario 4 initial lower");
        assertEq(scenario4.initialUpper, 8, "scenario 4 initial upper");
        assertEq(scenario4.rebalanceCount, 2, "scenario 4 rebalance count");
        assertEq(scenario4.blocks[0], 438567069, "scenario 4 first rebalance block");
        assertEq(scenario4.blocks[1], 446153834, "scenario 4 second rebalance block");

        assertEq(scenario5.initialLower, -2, "scenario 5 initial lower");
        assertEq(scenario5.initialUpper, 8, "scenario 5 initial upper");
        assertEq(scenario5.rebalanceCount, 2, "scenario 5 rebalance count");
        assertEq(scenario5.blocks[0], 438567069, "scenario 5 first rebalance block");
        assertEq(scenario5.blocks[1], 446153834, "scenario 5 second rebalance block");
    }

    function _buildSchedule(TickRangeScenario memory scenario) internal returns (ScenarioSchedule memory schedule_) {
        uint256[7] memory checkpoints = _historicalRebalanceBlocks();
        int24 startTick = _tickAtBlock(checkpoints[0]);

        // Each scenario starts by centering its range around the first historical checkpoint tick.
        int24 lower = startTick + scenario.lowerOffset;
        int24 upper = startTick + scenario.upperOffset;

        schedule_.initialLower = lower;
        schedule_.initialUpper = upper;

        // This intentionally uses the historical rebalance blocks as the observation cadence.
        // It answers: "on the dates we actually checked/rebalanced, which alternative ranges
        // would still have required a rebalance under the legacy deployed flow?"
        for (uint256 i = 1; i < checkpoints.length; ++i) {
            int24 tick = _tickAtBlock(checkpoints[i]);

            // Uniswap V3 ranges are lower-inclusive and upper-exclusive.
            // If the observed spot tick is outside the active range, we treat this checkpoint
            // as a required rebalance and recenter using the same scenario offsets.
            if (tick < lower || tick >= upper) {
                schedule_.blocks[schedule_.rebalanceCount] = checkpoints[i];
                schedule_.ticks[schedule_.rebalanceCount] = tick;

                lower = tick + scenario.lowerOffset;
                upper = tick + scenario.upperOffset;

                schedule_.newLowers[schedule_.rebalanceCount] = lower;
                schedule_.newUppers[schedule_.rebalanceCount] = upper;
                ++schedule_.rebalanceCount;
            }
        }
    }

    function _historicalRebalanceBlocks() internal pure returns (uint256[7] memory checkpoints_) {
        // These are the real historical rebalance transactions indexed for the live strategy.
        checkpoints_[0] = 432300739;
        checkpoints_[1] = 435765894;
        checkpoints_[2] = 438567069;
        checkpoints_[3] = 439991964;
        checkpoints_[4] = 441749173;
        checkpoints_[5] = 444159112;
        checkpoints_[6] = 446153834;
    }

    function _tickAtBlock(uint256 blockNumber) internal returns (int24 tick_) {
        // Reuse the same fork and roll it to each checkpoint so we can read the actual pool tick
        // from historical chain state without executing any swaps or position manager actions.
        vm.rollFork(forkId, blockNumber);
        (, tick_,,,,,) = pool.slot0();
    }

    function _logScenario(string memory label, ScenarioSchedule memory schedule_) internal pure {
        console2.log("====================================");
        console2.log(label);
        console2.log("initial range lower tick:");
        console2.logInt(schedule_.initialLower);
        console2.log("initial range upper tick:");
        console2.logInt(schedule_.initialUpper);
        console2.log("rebalance count:", schedule_.rebalanceCount);

        int24 activeLower = schedule_.initialLower;
        int24 activeUpper = schedule_.initialUpper;

        for (uint256 i; i < schedule_.rebalanceCount; ++i) {
            // `activeLower/activeUpper` track the range that would have been live immediately
            // before this checkpoint under the scenario being printed.
            console2.log("------------------------------------");
            console2.log("rebalance number:", i + 1);
            console2.log("historical checkpoint block:", schedule_.blocks[i]);
            console2.log("historical checkpoint date (UTC+0):");
            console2.log(_checkpointLabelUtc(schedule_.blocks[i]));
            console2.log("range before rebalance lower tick:");
            console2.logInt(activeLower);
            console2.log("range before rebalance upper tick:");
            console2.logInt(activeUpper);
            console2.log("observed spot tick at checkpoint:");
            console2.logInt(schedule_.ticks[i]);
            console2.log("new range lower tick after rebalance:");
            console2.logInt(schedule_.newLowers[i]);
            console2.log("new range upper tick after rebalance:");
            console2.logInt(schedule_.newUppers[i]);

            activeLower = schedule_.newLowers[i];
            activeUpper = schedule_.newUppers[i];
        }
    }

    function _checkpointLabelUtc(uint256 blockNumber) internal pure returns (string memory label_) {
        if (blockNumber == 432300739) return "2026-02-15 08:49:42 UTC+0";
        if (blockNumber == 435765894) return "2026-02-25 08:46:18 UTC+0";
        if (blockNumber == 438567069) return "2026-03-05 10:49:45 UTC+0";
        if (blockNumber == 439991964) return "2026-03-09 13:38:08 UTC+0";
        if (blockNumber == 441749173) return "2026-03-14 15:46:40 UTC+0";
        if (blockNumber == 444159112) return "2026-03-21 15:20:44 UTC+0";
        if (blockNumber == 446153834) return "2026-03-27 09:44:22 UTC+0";
        return "unknown checkpoint";
    }

    function _getAddr(string memory contractName) internal view returns (address) {
        return addrGetter.getAddress(block.chainid, contractName);
    }
}

contract AddressGetter is GetContractAddress {
    function getAddress(uint256 chainId, string memory contractName) external view returns (address) {
        return _getContractAddress(chainId, contractName);
    }
}

/*
      Date (UTC)	    Block	   Old Range	New Range	Swap In	     Swap Out	   Drag
2026-02-15 08:49:42	  432300739	   5 to 10	    1 to 5	   317.348613	317.415240	  0.066627
2026-02-25 08:46:18	  435765894	   1 to 5	   -2 to 3	  2539.653076	2539.504202	  0.148874
2026-03-05 10:49:45	  438567069	  -2 to 3	   -5 to 0	  3150.866256	3149.776361	  1.089895
2026-03-09 13:38:08	  439991964	  -5 to 0	   -2 to 3	  4250.802369	4250.019402	  0.782967
2026-03-14 15:46:40	  441749173	  -2 to 3	   -5 to 0	  4603.287642	4601.683543	  1.604099
2026-03-21 15:20:44	  444159112	  -5 to 0	   -2 to 3	  6214.150378	6213.083093	  1.067285
2026-03-27 09:44:22	  446153834	  -2 to 3	    1 to 6	  9525.563619	9521.156263	  4.407356

*/
