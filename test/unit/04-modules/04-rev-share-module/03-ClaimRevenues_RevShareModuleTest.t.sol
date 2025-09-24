// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";

contract ClaimRevenues_RevShareModuleTest is StdCheats, Test {
    TestDeployProtocol deployer;
    RevShareModule revShareModule;
    RevShareNFT nft;
    HelperConfig helperConfig;
    IUSDC usdc;
    address takadao;
    address revenueClaimer; // has REVENUE_CLAIMER role
    address revenueReceiver; // destination account for Takadao claims
    address module;
    address revShareModuleAddress;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    function setUp() public {
        deployer = new TestDeployProtocol();
        (, , module, , , , revShareModuleAddress, , , , helperConfig) = deployer.run();

        revShareModule = RevShareModule(revShareModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        revenueClaimer = takadao;

        // Fresh RevShareNFT proxy
        string
            memory baseURI = "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/";
        address nftImplementation = address(new RevShareNFT());
        address nftAddress = UnsafeUpgrades.deployUUPSProxy(
            nftImplementation,
            abi.encodeCall(RevShareNFT.initialize, (baseURI, msg.sender))
        );
        nft = RevShareNFT(nftAddress);

        // Read AddressManager from RevShareModule.storage slot 0
        bytes32 amSlot = vm.load(address(revShareModule), bytes32(uint256(0)));
        AddressManager addressManager = AddressManager(address(uint160(uint256(amSlot))));

        revenueReceiver = addressManager.getProtocolAddressByName("REVENUE_RECEIVER").addr;
        usdc = IUSDC(addressManager.getProtocolAddressByName("CONTRIBUTION_TOKEN").addr);

        // Register NFT + an authorized Module caller for notifyNewRevenue
        vm.startPrank(addressManager.owner());
        addressManager.addProtocolAddress(
            "REVSHARE_NFT",
            address(nft),
            ProtocolAddressType.Protocol
        );
        vm.stopPrank();

        // Staggered mints to create non-uniform join times
        vm.prank(nft.owner());
        nft.batchMint(alice, 50);

        _warp(1 days);
        vm.prank(nft.owner());
        nft.batchMint(bob, 25);

        _warp(3 days);
        vm.prank(nft.owner());
        nft.batchMint(charlie, 84);

        _warp(15 days);

        // Fund + notify first stream (module default duration = 90 days unless changed)
        deal(address(usdc), module, 11_000e6); // 11,000 USDC
        vm.startPrank(module);
        usdc.approve(address(revShareModule), 11_000e6);
        revShareModule.notifyNewRevenue(11_000e6);
        vm.stopPrank();

        // Force totalSupply to a known value for deterministic per-NFT math
        uint256 forcedTotalSupply = 1_500;
        vm.store(
            address(nft),
            bytes32(uint256(2)), // totalSupply slot in this NFT
            bytes32(forcedTotalSupply)
        );
    }

    /*//////////////////////////////////////////////////////////////
                               TESTS
    //////////////////////////////////////////////////////////////*/

    /// Claim immediately after deposit -> no elapsed time => 0
    function testRevShareModule_pioneerImmediateClaimReturnsZero() public {
        vm.prank(alice);
        uint256 claimed = revShareModule.claimRevenueShare();
        assertEq(claimed, 0, "claim should be zero without elapsed time");
    }

    /// After some time: pioneer earns > 0; RR earns 0 in pioneers view; RR earns > 0 in Takadao view
    function testRevShareModule_gettersEarnedViewsGateProperly() public {
        _warp(2 days);

        uint256 earnedAlice = revShareModule.earnedByPioneers(alice);
        assertGt(earnedAlice, 0, "pioneer earned should be > 0");

        // RR should not earn from pioneers stream
        uint256 earnedRRinPioneers = revShareModule.earnedByPioneers(revenueReceiver);
        assertEq(earnedRRinPioneers, 0, "revenueReceiver should not earn in pioneers view");

        // Takadao accrues globally, independent of NFT balance
        uint256 earnedRRinTakadao = revShareModule.earnedByTakadao(revenueReceiver);
        assertGt(earnedRRinTakadao, 0, "revenueReceiver should accrue in Takadao view");
    }

    /// Pioneer: first claim pays and zeroes; second immediate claim returns 0
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

    /// A random non-pioneer and non-claimer cannot claim
    function testRevShareModule_nonPioneerNonClaimerReverts() public {
        address dave = makeAddr("dave");
        vm.expectRevert(ModuleErrors.Module__NotAuthorizedCaller.selector);
        vm.prank(dave);
        revShareModule.claimRevenueShare();
    }

    /// Takadao path: WITHOUT NFT balance -> accrues globally and pays to revenueReceiver
    function testRevShareModule_takadaoClaimerPaysReceiver_NoNFTs() public {
        _warp(2 days);

        uint256 preRRBal = usdc.balanceOf(revenueReceiver);
        uint256 preApproved = revShareModule.approvedDeposits();

        vm.prank(revenueClaimer);
        uint256 claimed = revShareModule.claimRevenueShare();

        assertGt(claimed, 0, "takadao should claim > 0 without NFT balance");
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

    /// Getters: pioneers per-NFT accumulator grows with time
    function testRevShareModule_perNftAccumulatorGrowsOverTime() public {
        uint256 a = revShareModule.getRevenuePerNftOwnedByPioneers();
        _warp(6 hours);
        uint256 b = revShareModule.getRevenuePerNftOwnedByPioneers();
        assertGt(b, a, "pioneers per-NFT accumulator should increase");
    }

    /// getRevenueForDuration(dur) returns each pool’s streamed amount (after per-second floors)
    function testRevShareModule_getRevenueForDurationSumsToDepositAmount() public view {
        uint256 dur = revShareModule.rewardsDuration();
        (uint256 p, uint256 t) = revShareModule.getRevenueForDuration(dur);

        // Known from setUp
        uint256 amount = 11_000e6;

        // Mirror contract's split
        uint256 pShare = (amount * 75) / 100;
        uint256 tShare = (amount * 25) / 100;

        // Expected streamed amounts after fixed-point floors
        uint256 expectedP = (((pShare * 1e18) / dur) * dur) / 1e18;
        uint256 expectedT = (((tShare * 1e18) / dur) * dur) / 1e18;

        assertEq(p, expectedP, "pioneers streamed part mismatches");
        assertEq(t, expectedT, "takadao streamed part mismatches");
        assertEq(p + t, expectedP + expectedT, "sum of streamed parts");

        // Dust = unstreamed remainder from per-second floors
        uint256 expectedDust = (pShare - expectedP) + (tShare - expectedT);
        assertEq(amount - (p + t), expectedDust, "dust accounted");
    }

    /// lastTimeApplicable caps at periodFinish
    function testRevShareModule_lastTimeApplicableCapsAtPF() public {
        uint256 pf = revShareModule.periodFinish();
        assertTrue(pf > block.timestamp, "stream should be active at setup");
        _warp(pf - block.timestamp + 1 hours);
        assertEq(revShareModule.lastTimeApplicable(), pf, "should cap at periodFinish");
    }

    /// Guard: insufficient approvedDeposits reverts on payout
    function testRevShareModule_approvedDepositsGuardRevertWhenInsufficient() public {
        _warp(2 days);

        // Force approvedDeposits to 0 (slot 4 in current layout)
        vm.store(address(revShareModule), bytes32(uint256(4)), bytes32(uint256(0)));

        vm.expectRevert(RevShareModule.RevShareModule__InsufficientApprovedDeposits.selector);
        vm.prank(bob);
        revShareModule.claimRevenueShare();
    }

    /// updateRevenue(address(0)) path: only updates globals and returns (no revert)
    function testRevShareModule_updateRevenueZeroAddressOnlyGlobal() public {
        revShareModule.updateRevenue(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
    }
}
