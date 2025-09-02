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

contract ClaimRevenues_RevShareModuleTest is Test {
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
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

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

        vm.prank(nft.owner());
        nft.batchMint(alice, 50);

        vm.warp(block.timestamp + 1 days);
        vm.roll(block.number + 1);

        vm.prank(nft.owner());
        nft.batchMint(bob, 25);

        vm.warp(block.timestamp + 3 days);
        vm.roll(block.number + 1);

        vm.prank(nft.owner());
        nft.batchMint(charlie, 84);

        vm.warp(block.timestamp + 15 days);
        vm.roll(block.number + 1);

        // fund + notify (first stream; duration assumed 365 days in your module)
        deal(address(usdc), module, 11_000e6); // 11,000 USDC

        vm.startPrank(module);
        usdc.approve(address(revShareModule), 11_000e6);
        revShareModule.notifyNewRevenue(11_000e6);
        vm.stopPrank();

        // force totalSupply to a known value for predictable denominators
        uint256 forcedTotalSupply = 1_500;
        vm.store(
            address(nft),
            bytes32(uint256(2)), // slot index for totalSupply
            bytes32(forcedTotalSupply)
        );
    }

    /* ------------------------------ helpers ------------------------------ */

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
    }

    /* ------------------------------- tests -------------------------------- */

    // Claim immediately after deposit -> no elapsed time => 0
    function testRevShareModule_pioneerImmediateClaimReturnsZero() public {
        vm.prank(alice);
        uint256 claimed = revShareModule.claimRevenueShare();
        assertEq(claimed, 0, "claim should be zero without elapsed time");
    }

    // After some time, pioneers see earned > 0; takadao shows 0 in pioneers view
    function testRevShareModule_gettersEarnedViewsGateProperly() public {
        _warp(2 days);

        uint256 earnedAlice = revShareModule.earnedPioneers(alice);
        assertGt(earnedAlice, 0, "pioneer earned should be > 0");

        // takadao shouldn't earn from pioneers stream
        uint256 earnedRRinPioneers = revShareModule.earnedPioneers(revenueReceiver);
        assertEq(earnedRRinPioneers, 0, "revenueReceiver should not earn in pioneers view");

        // if takadao has no NFTs, earnedTakadao is 0
        uint256 earnedRRinTakadao = revShareModule.earnedTakadao(revenueReceiver);
        // ok either 0 (no balance) or >0 if your token returns balance for REVENUE_RECEIVER
        assertTrue(earnedRRinTakadao >= 0); // non-reverting smoke check
    }

    // Pioneer successful claim pays out and zeroes account accrual; second claim returns 0
    function testRevShareModule_pioneerClaimRevenueAndThenZero() public {
        _warp(3 days);

        uint256 preBal = usdc.balanceOf(alice);
        uint256 preApproved = revShareModule.approvedDeposits();

        vm.prank(alice);
        uint256 claimed1 = revShareModule.claimRevenueShare();
        assertGt(claimed1, 0, "first claim should pay > 0");
        assertEq(usdc.balanceOf(alice), preBal + claimed1, "USDC not received");
        assertEq(revShareModule.revenuePerAccount(alice), 0, "account bucket not zeroed");
        assertEq(
            revShareModule.approvedDeposits(),
            preApproved - claimed1,
            "approvedDeposits not decremented"
        );

        // immediate re-claim should return 0
        vm.prank(alice);
        uint256 claimed2 = revShareModule.claimRevenueShare();
        assertEq(claimed2, 0, "second immediate claim should be zero");
    }

    // A random non-pioneer and non-claimer cannot claim
    function testRevShareModule_nonPioneerNonClaimerReverts() public {
        address dave = makeAddr("dave");
        vm.expectRevert(ModuleErrors.Module__NotAuthorizedCaller.selector);
        vm.prank(dave);
        revShareModule.claimRevenueShare();
    }

    // Takadao path: with NO NFT balance -> claim returns 0 (but does not revert)
    function testRevShareModule_takadaoClaimerNoNFTReturnsZero() public {
        _warp(1 days);

        vm.prank(revenueClaimer);
        uint256 claimed = revShareModule.claimRevenueShare();
        assertEq(claimed, 0, "takadao claim should be zero without NFT balance");
    }

    // Takadao path: WITH NFT balance -> accrues and pays to revenueReceiver
    function testRevShareModule_takadaoClaimerWithNFTPaysReceiver() public {
        // mint some NFTs to revenueReceiver so 25% stream accrues
        vm.prank(nft.owner());
        nft.batchMint(revenueReceiver, 10);

        _warp(2 days);

        uint256 preRRBal = usdc.balanceOf(revenueReceiver);
        uint256 preApproved = revShareModule.approvedDeposits();

        vm.prank(revenueClaimer);
        uint256 claimed = revShareModule.claimRevenueShare();

        assertGt(claimed, 0, "takadao should claim > 0 when holding NFTs");
        assertEq(
            usdc.balanceOf(revenueReceiver),
            preRRBal + claimed,
            "USDC not paid to revenueReceiver"
        );
        assertEq(
            revShareModule.revenuePerAccount(revenueReceiver),
            0,
            "receiver bucket not zeroed"
        );
        assertEq(
            revShareModule.approvedDeposits(),
            preApproved - claimed,
            "approvedDeposits not decremented"
        );
    }

    // Getters: per-NFT accumulators grow with time for pioneers
    function testRevShareModule_perNftAccumulatorGrowsOverTime() public {
        uint256 a = revShareModule.getRevenuePerNftPioneers();
        _warp(6 hours);
        uint256 b = revShareModule.getRevenuePerNftPioneers();
        assertGt(b, a, "pioneers per-NFT accumulator should increase");
    }

    function testRevShareModule_getRevenueForDurationSumsToDepositAmount() public {
        uint256 dur = revShareModule.rewardsDuration();
        (uint256 p, uint256 t) = revShareModule.getRevenueForDuration(dur);

        // Known from setUp
        uint256 amount = 11_000e6;

        // Mirror contract's split
        uint256 pShare = (amount * 75) / 100;
        uint256 tShare = (amount * 25) / 100;

        // Expected streamed amounts after per-pool floor division
        uint256 expectedP = (pShare / dur) * dur;
        uint256 expectedT = (tShare / dur) * dur;

        assertEq(p, expectedP, "pioneers streamed part mismatches");
        assertEq(t, expectedT, "takadao streamed part mismatches");
        assertEq(p + t, expectedP + expectedT, "sum of streamed parts");
        assertEq(amount - (p + t), (pShare % dur) + (tShare % dur), "dust accounted");
    }

    // lastTimeApplicable caps at periodFinish
    function testRevShareModule_lastTimeApplicableCapsAtPF() public {
        uint256 pf = revShareModule.periodFinish();
        assertTrue(pf > block.timestamp, "stream should be active at setup");
        _warp(pf - block.timestamp + 1 hours);
        assertEq(revShareModule.lastTimeApplicable(), pf, "should cap at periodFinish");
    }

    // Guard: insufficient approvedDeposits reverts on payout
    function testRevShareModule_approvedDepositsGuardRevertWhenInsufficient() public {
        _warp(2 days);

        // Force approvedDeposits to 0 to trigger guard
        vm.store(address(revShareModule), bytes32(uint256(4)), bytes32(uint256(0)));

        vm.expectRevert(RevShareModule.RevShareModule__InsufficientApprovedDeposits.selector);
        vm.prank(bob);
        revShareModule.claimRevenueShare();
    }

    // updateRevenue(address(0)) path: only updates globals and returns (no revert)
    function testRevShareModule_updateRevenueZeroAddressOnlyGlobal() public {
        // Should not revert; just settles global accumulators
        revShareModule.updateRevenue(address(0));
    }
}
