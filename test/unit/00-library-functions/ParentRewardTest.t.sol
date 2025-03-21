// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {ParentRewardsHarness} from "../../helpers/harness/ParentRewardsHarness.t.sol";

contract ParentRewardTest is Test {
    ParentRewardsHarness public parentRewardsHarness;

    function setUp() public {
        parentRewardsHarness = new ParentRewardsHarness();
    }

    function testParentReward() public {
        // This is a virtual function with no implementation
        (uint256 a, uint256 b) = parentRewardsHarness.exposed__parentRewards(
            address(0),
            0,
            0,
            0,
            0
        );

        assertEq(a, 0);
        assertEq(b, 0);
    }

    function testReferralRewardRatioByLayer() public view {
        uint256 layer1 = parentRewardsHarness.exposed__referralRewardRatioByLayer(1);
        uint256 layer2 = parentRewardsHarness.exposed__referralRewardRatioByLayer(2);
        uint256 layer3 = parentRewardsHarness.exposed__referralRewardRatioByLayer(3);
        uint256 layer4 = parentRewardsHarness.exposed__referralRewardRatioByLayer(4);

        assertEq(layer1, 40_000);
        assertEq(layer2, 10_000);
        assertEq(layer3, 3_500);
        assertEq(layer4, 1_750);
    }
}
