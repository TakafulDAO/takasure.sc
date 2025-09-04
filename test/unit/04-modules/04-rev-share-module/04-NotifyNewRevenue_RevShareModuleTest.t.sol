// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

contract NotifyNewRevenue_RevShareModuleTest is Test {
    TestDeployProtocol deployer;
    RevShareModule revShareModule;
    RevShareNFT nft;
    HelperConfig helperConfig;
    IUSDC usdc;
    address takadao;
    address revenueClaimer;
    address revenueReceiver;
    address module = makeAddr("module");
    address revShareModuleAddress;

    event OnDeposit(uint256 amount);
    event OnBalanceSwept(uint256 amount);

    function setUp() public {
        deployer = new TestDeployProtocol();
        (, , , , , , revShareModuleAddress, , , , helperConfig) = deployer.run();

        revShareModule = RevShareModule(revShareModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        takadao = config.takadaoOperator;
        revenueClaimer = takadao;

        string
            memory baseURI = "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/";
        address nftImplementation = address(new RevShareNFT());
        address nftAddress = UnsafeUpgrades.deployUUPSProxy(
            nftImplementation,
            abi.encodeCall(RevShareNFT.initialize, (baseURI, msg.sender))
        );
        nft = RevShareNFT(nftAddress);

        uint256 addressManagerAddressSlot = 0;
        bytes32 addressManagerAddressSlotBytes = vm.load(
            address(revShareModule),
            bytes32(uint256(addressManagerAddressSlot))
        );
        AddressManager addressManager = AddressManager(
            address(uint160(uint256(addressManagerAddressSlotBytes)))
        );

        revenueReceiver = addressManager.getProtocolAddressByName("REVENUE_RECEIVER").addr;
        usdc = IUSDC(addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr);

        vm.startPrank(addressManager.owner());
        addressManager.addProtocolAddress("REVSHARE_NFT", address(nft), ProtocolAddressType.Module);
        addressManager.addProtocolAddress("RANDOM_MODULE", module, ProtocolAddressType.Module);
        vm.stopPrank();

        // fund + notify (first stream; duration assumed 365 days)
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

        uint256 oldRateP = revShareModule.rewardRatePioneers();
        uint256 oldRateT = revShareModule.rewardRateTakadao();
        uint256 oldPF = revShareModule.periodFinish();
        uint256 oldRevPerNftP = revShareModule.getRevenuePerNftPioneers();
        uint256 oldRevPerNftT = revShareModule.getRevenuePerNftTakadao();

        // remaining time
        uint256 remaining = oldPF > block.timestamp ? (oldPF - block.timestamp) : 0;
        assertGt(remaining, 0, "should still be active");

        // New deposit
        uint256 amount = 9_000e6;
        uint256 pShare = (amount * 75) / 100;
        uint256 tShare = (amount * 25) / 100;

        // Expected new rates = (new share + leftover) / dur
        uint256 expectedP = (pShare + (remaining * oldRateP)) / dur;
        uint256 expectedT = (tShare + (remaining * oldRateT)) / dur;

        _fundAndNotify(module, amount);

        // Rates updated with carry-over
        assertEq(
            revShareModule.rewardRatePioneers(),
            expectedP,
            "pioneers rate carryover mismatch"
        );
        assertEq(revShareModule.rewardRateTakadao(), expectedT, "takadao rate carryover mismatch");

        // periodFinish reset to now + dur
        assertEq(revShareModule.periodFinish(), block.timestamp + dur, "period finish not reset");

        // lastUpdateTime bumped
        assertEq(
            revShareModule.lastTimeApplicable(),
            revShareModule.lastTimeApplicable(),
            "sanity"
        );
        assertEq(
            revShareModule.lastTimeApplicable(),
            block.timestamp,
            "last time applicable should be now or capped"
        );

        // Global accumulators settled before rate change (monotonic increase when supply > 0)
        uint256 newRevPerNftP = revShareModule.getRevenuePerNftPioneers();
        uint256 newRevPerNftT = revShareModule.getRevenuePerNftTakadao();
        assertGe(newRevPerNftP, oldRevPerNftP, "revenuePerNftPioneers should not decrease");
        assertGe(newRevPerNftT, oldRevPerNftT, "revenuePerNftTakadao should not decrease");
    }

    // 4) New stream after finish (no carry-over)
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

        uint256 expectedP = pShare / dur;
        uint256 expectedT = tShare / dur;

        _fundAndNotify(module, amount);

        assertEq(revShareModule.rewardRatePioneers(), expectedP, "pioneers rate mismatch");
        assertEq(revShareModule.rewardRateTakadao(), expectedT, "takadao rate mismatch");
        assertEq(revShareModule.periodFinish(), block.timestamp + dur, "period finish mismatch");
    }

    // 5) Accounting + token balance: approvedDeposits & contract USDC increase
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

    // 6) _updateGlobal with totalSupply == 0: accumulators unchanged
    function testRevShareModule_notifyUpdateGlobalZeroSupplyNoAccrual() public {
        // Force totalSupply to 0 before calling notify
        uint256 slotTotalSupply = 2;
        vm.store(address(nft), bytes32(slotTotalSupply), bytes32(uint256(0)));

        uint256 beforeP = revShareModule.getRevenuePerNftPioneers();
        uint256 beforeT = revShareModule.getRevenuePerNftTakadao();

        _warp(3 days);

        // Another deposit to trigger _updateGlobal inside notify
        _fundAndNotify(module, 1_000e6);

        uint256 afterP = revShareModule.getRevenuePerNftPioneers();
        uint256 afterT = revShareModule.getRevenuePerNftTakadao();

        // With totalSupply == 0, _revenuePerNft* returns previous accumulator unmodified
        assertEq(afterP, beforeP, "pioneers accumulator should remain unchanged when supply == 0");
        assertEq(afterT, beforeT, "takadao accumulator should remain unchanged when supply == 0");
    }

    // 7) getRevenueForDuration scales with duration using current rates
    function testRevShareModule_getRevenueForDurationScales() public view {
        // arbitrary sub-duration (e.g., 3 days)
        uint256 sub = 3 days;
        (uint256 p, uint256 t) = revShareModule.getRevenueForDuration(sub);

        // Expected from current rates
        uint256 expectedP = revShareModule.rewardRatePioneers() * sub;
        uint256 expectedT = revShareModule.rewardRateTakadao() * sub;

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
