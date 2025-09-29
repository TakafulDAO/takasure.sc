// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

contract NotifyNewRevenue_RevShareModuleTest is Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    RevShareModule revShareModule;
    RevShareNFT nft;

    IUSDC usdc;
    address takadao;
    address revenueClaimer;
    address revenueReceiver;
    address module;
    address revShareModuleAddress;

    event OnDeposit(uint256 amount);
    event OnBalanceSwept(uint256 amount);

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addrMgr,
            ModuleManager modMgr
        ) = managersDeployer.run();

        (address operatorAddr, , , , , , address revReceiver) = addressesAndRoles.run(
            addrMgr,
            config,
            address(modMgr)
        );

        SubscriptionModule subscriptions;
        (, , , , , , revShareModule, subscriptions) = moduleDeployer.run(addrMgr);

        module = address(subscriptions);

        takadao = operatorAddr;
        revenueClaimer = takadao;

        string
            memory baseURI = "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/";
        address nftImplementation = address(new RevShareNFT());
        address nftAddress = UnsafeUpgrades.deployUUPSProxy(
            nftImplementation,
            abi.encodeCall(RevShareNFT.initialize, (baseURI, msg.sender))
        );
        nft = RevShareNFT(nftAddress);

        revenueReceiver = revReceiver;
        usdc = IUSDC(config.contributionToken);

        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("REVSHARE_NFT", address(nft), ProtocolAddressType.Protocol);
        vm.stopPrank();

        // fund + notify (first stream; uses default rewardsDuration)
        deal(address(usdc), module, 11_000e6); // 11,000 USDC

        vm.startPrank(module);
        usdc.approve(address(revShareModule), 11_000e6);
        revShareModule.notifyNewRevenue(11_000e6);
        vm.stopPrank();

        // force totalSupply to a known value
        uint256 forcedTotalSupply = 1_500;
        vm.store(
            address(nft),
            bytes32(uint256(2)), // slot index for totalSupply
            bytes32(forcedTotalSupply)
        );
    }

    function testRevShareModule_notifyCarryoverMathDuringActiveStream() public {
        // Ensure we are clearly mid-stream
        uint256 dur = revShareModule.rewardsDuration();
        _warp(dur / 10); // move ~10% into the stream

        uint256 oldRateP = revShareModule.rewardRatePioneersScaled();
        uint256 oldRateT = revShareModule.rewardRateTakadaoScaled();
        uint256 oldPF = revShareModule.periodFinish();
        uint256 oldRevPerNftP = revShareModule.getRevenuePerNftOwnedByPioneers();
        uint256 oldRevPerNftT = revShareModule.getTakadaoRevenueScaled();

        // remaining time
        uint256 remaining = oldPF > block.timestamp ? (oldPF - block.timestamp) : 0;
        assertGt(remaining, 0, "should still be active");

        // New deposit
        uint256 amount = 9_000e6;
        uint256 pShare = (amount * 75) / 100;
        uint256 tShare = (amount * 25) / 100;

        // Expected new *scaled* rates = (new share (scaled) + leftover (scaled)) / dur
        uint256 expectedP = (pShare * 1e18 + (remaining * oldRateP)) / dur;
        uint256 expectedT = (tShare * 1e18 + (remaining * oldRateT)) / dur;

        _fundAndNotify(module, amount);

        // Rates updated with carry-over
        assertEq(
            revShareModule.rewardRatePioneersScaled(),
            expectedP,
            "pioneers rate carryover mismatch"
        );
        assertEq(
            revShareModule.rewardRateTakadaoScaled(),
            expectedT,
            "takadao rate carryover mismatch"
        );

        // periodFinish reset to now + dur
        assertEq(revShareModule.periodFinish(), block.timestamp + dur, "period finish not reset");

        // lastUpdateTime bumped (sanity)
        assertEq(
            revShareModule.lastTimeApplicable(),
            revShareModule.lastTimeApplicable(),
            "sanity"
        );
        assertEq(revShareModule.lastTimeApplicable(), block.timestamp, "lta should be now/capped");

        // Global accumulators settled before rate change (monotonic)
        uint256 newRevPerNftP = revShareModule.getRevenuePerNftOwnedByPioneers();
        uint256 newRevPerNftT = revShareModule.getTakadaoRevenueScaled();
        assertGe(newRevPerNftP, oldRevPerNftP, "pioneers accumulator decreased");
        assertGe(newRevPerNftT, oldRevPerNftT, "takadao accumulator decreased");
    }

    // New stream after finish (no carry-over)
    function testRevShareModule_notifyNewStreamAfterFinishNoCarryover() public {
        // Fast-forward to after the current periodFinish
        uint256 pf = revShareModule.periodFinish();
        if (pf == 0 || block.timestamp <= pf) {
            _warp((pf == 0 ? 0 : (pf - block.timestamp)) + 1);
        }

        uint256 dur = revShareModule.rewardsDuration();

        uint256 amount = 5_000e6;
        uint256 pShare = (amount * 75) / 100;
        uint256 tShare = (amount * 25) / 100;

        uint256 expectedP = (pShare * 1e18) / dur;
        uint256 expectedT = (tShare * 1e18) / dur;

        _fundAndNotify(module, amount);

        assertEq(revShareModule.rewardRatePioneersScaled(), expectedP, "pioneers rate mismatch");
        assertEq(revShareModule.rewardRateTakadaoScaled(), expectedT, "takadao rate mismatch");
        assertEq(revShareModule.periodFinish(), block.timestamp + dur, "period finish mismatch");
    }

    // Accounting + token balance: approvedDeposits & contract USDC increase
    function testRevShareModule_notifyUpdatesApprovedDepositsAndBalance() public {
        uint256 amount = 777e6;
        uint256 prevApproved = revShareModule.approvedDeposits();
        uint256 prevBal = usdc.balanceOf(address(revShareModule));

        _fundAndNotify(module, amount);

        assertEq(
            revShareModule.approvedDeposits(),
            prevApproved + amount,
            "approvedDeposits not incremented"
        );
        assertEq(
            usdc.balanceOf(address(revShareModule)),
            prevBal + amount,
            "module token balance not incremented"
        );
    }

    /// _updateGlobal with totalSupply == 0:
    ///  - Pioneers accumulator remains unchanged (75% path short-circuits),
    ///  - Takadao accumulator *does* increase (25% global stream).
    function testRevShareModule_notifyUpdateGlobalZeroSupply_GlobalTakadaoContinues() public {
        // Force totalSupply to 0 before calling notify
        uint256 slotTotalSupply = 2;
        vm.store(address(nft), bytes32(slotTotalSupply), bytes32(uint256(0)));

        // Snapshot current Takadao rate & accumulators
        uint256 beforeP = revShareModule.getRevenuePerNftOwnedByPioneers();
        uint256 beforeT = revShareModule.getTakadaoRevenueScaled();
        uint256 oldRateT = revShareModule.rewardRateTakadaoScaled();

        // Let time pass so _updateGlobal has elapsed to settle on notify()
        uint256 elapsed = 3 days;
        _warp(elapsed);

        // Another deposit to trigger _updateGlobal inside notify
        _fundAndNotify(module, 1_000e6);

        uint256 afterP = revShareModule.getRevenuePerNftOwnedByPioneers();
        uint256 afterT = revShareModule.getTakadaoRevenueScaled();

        // With totalSupply == 0, pioneers accumulator stays unchanged
        assertEq(afterP, beforeP, "pioneers accumulator should remain unchanged when supply == 0");

        // Takadao accumulator increases by elapsed * oldRateT (global stream keeps accruing)
        uint256 expectedAfterT = beforeT + (elapsed * oldRateT);
        assertEq(afterT, expectedAfterT, "takadao accumulator delta mismatch when supply == 0");
    }

    // getRevenueForDuration scales with duration using current rates
    function testRevShareModule_getRevenueForDurationScales() public view {
        // arbitrary sub-duration (e.g., 3 days)
        uint256 sub = 3 days;
        (uint256 p, uint256 t) = revShareModule.getRevenueForDuration(sub);

        // Expected from current *scaled* rates → convert back to token units
        uint256 expectedP = (revShareModule.rewardRatePioneersScaled() * sub) / 1e18;
        uint256 expectedT = (revShareModule.rewardRateTakadaoScaled() * sub) / 1e18;

        assertEq(p, expectedP, "pioneers duration scaling mismatch");
        assertEq(t, expectedT, "takadao duration scaling mismatch");
    }

    /*//////////////////////////////////////////////////////////////
                      SWEEP NON APPROVED DEPOSITS
    //////////////////////////////////////////////////////////////*/

    // Extra funds exist -> sweep to caller (operator)
    function testRevShareModule_sweepWithExtraSendsToOperatorAndEmits() public {
        // Add 1,234 USDC directly to the module without touching approvedDeposits
        uint256 extra = 1_234e6;
        deal(
            address(usdc),
            address(revShareModule),
            usdc.balanceOf(address(revShareModule)) + extra
        );

        uint256 beforeOpBal = usdc.balanceOf(takadao);
        uint256 beforeModBal = usdc.balanceOf(address(revShareModule));
        uint256 beforeApproved = revShareModule.approvedDeposits();

        // Expect event
        vm.expectEmit(address(revShareModule));
        emit OnBalanceSwept(extra);

        vm.prank(takadao);
        revShareModule.sweepNonApprovedDeposits();

        uint256 afterOpBal = usdc.balanceOf(takadao);
        uint256 afterModBal = usdc.balanceOf(address(revShareModule));
        uint256 afterApproved = revShareModule.approvedDeposits();

        assertEq(afterOpBal, beforeOpBal + extra, "operator did not receive swept funds");
        assertEq(afterModBal, beforeModBal - extra, "module balance not reduced by extra");
        assertEq(afterApproved, beforeApproved, "approvedDeposits must not change");
    }

    // After emergencyWithdraw -> nothing to sweep (balance 0, approved 0)
    function testRevShareModule_sweepAfterEmergencyWithdrawReverts() public {
        // prank as operator to call emergencyWithdraw
        vm.prank(takadao);
        revShareModule.emergencyWithdraw();

        assertEq(usdc.balanceOf(address(revShareModule)), 0, "module balance should be 0");
        assertEq(revShareModule.approvedDeposits(), 0, "approvedDeposits should be 0");

        vm.expectRevert(RevShareModule.RevShareModule__NothingToSweep.selector);
        vm.prank(takadao);
        revShareModule.sweepNonApprovedDeposits();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
    }

    function _fundAndNotify(address from, uint256 amount) internal {
        deal(address(usdc), from, amount);
        vm.startPrank(from);
        usdc.approve(address(revShareModule), amount);
        // Expect event
        vm.expectEmit(false, false, false, true, address(revShareModule));
        emit OnDeposit(amount);
        revShareModule.notifyNewRevenue(amount);
        vm.stopPrank();
    }
}
