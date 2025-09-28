// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {ProtocolAddressType} from "contracts/types/TakasureTypes.sol";

contract NotifyClaimInteraction_RevShareModuleTest is StdCheats, Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;

    RevShareModule revShareModule;
    RevShareNFT nft;

    IUSDC usdc;
    address takadao;
    address revenueClaimer; // has REVENUE_CLAIMER role
    address revenueReceiver; // destination account for Takadao claims
    address module;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

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

        // Fresh RevShareNFT proxy
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

        // Register NFT + an authorized Module caller for notifyNewRevenue
        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("REVSHARE_NFT", address(nft), ProtocolAddressType.Protocol);
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

        vm.prank(nft.owner());
        nft.setAddressManager(address(addrMgr));
    }

    /*//////////////////////////////////////////////////////////////
                               TESTS
    //////////////////////////////////////////////////////////////*/

    /// Single stream -> pioneer claim math matches exactly
    function testRevShareModule_pioneerClaimMathMatchesSingleStream() public {
        _setRewardsDuration365();

        // Start stream with 50,000 USDC
        uint256 amount = 50_000e6;
        _fundAndApprove(module, amount);
        _notify(module, amount);

        // Force a known totalSupply (denominator) to 1,500
        vm.store(address(nft), bytes32(uint256(2)), bytes32(uint256(1_500)));

        // Let time pass
        uint256 elapsed = 10 days; // 864,000 seconds
        _warp(elapsed);

        // --- Expected math (pioneers stream, fixed-point) ---
        uint256 pShare = (amount * 75) / 100; // 37,500e6
        uint256 dur = revShareModule.rewardsDuration(); // 31_536_000
        uint256 totalSupply = 1_500;
        uint256 balance = 50;

        // rateScaled = floor(pShare * 1e18 / dur)
        uint256 rateScaled = (pShare * 1e18) / dur;

        // per-NFT accumulator delta (scaled): floor(elapsed * rateScaled / totalSupply)
        uint256 deltaPerNftScaled = (elapsed * rateScaled) / totalSupply;

        // expected earned = floor(balance * deltaPerNftScaled / 1e18)
        uint256 expectedAlice = (balance * deltaPerNftScaled) / 1e18;

        // Sanity: view getter should match our math
        uint256 earnedView = revShareModule.earnedByPioneers(alice);
        assertEq(earnedView, expectedAlice, "earned view mismatch with math");

        // Claim and verify transfer
        uint256 pre = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = revShareModule.claimRevenueShare();
        assertEq(claimed, expectedAlice, "claim mismatch with math");
        assertEq(usdc.balanceOf(alice), pre + expectedAlice, "USDC not received by alice");

        // Re-claim immediately -> 0
        vm.prank(alice);
        assertEq(revShareModule.claimRevenueShare(), 0, "second claim should be zero");
    }

    /// Takadao claim (25% stream) — accrues globally, independent of NFT balances
    function testRevShareModule_takadaoClaimMathMatches_Global() public {
        _setRewardsDuration365();

        uint256 amount = 50_000e6;
        _fundAndApprove(module, amount);
        _notify(module, amount);

        uint256 elapsed = 5 days; // 432,000 sec
        _warp(elapsed);

        // --- Expected math (Takadao global stream, fixed-point) ---
        // rateScaled = floor(tShare * 1e18 / dur)
        // earned = floor(elapsed * rateScaled / 1e18)
        uint256 tShare = (amount * 25) / 100; // 12,500e6
        uint256 dur = revShareModule.rewardsDuration();
        uint256 rateScaled = (tShare * 1e18) / dur;
        uint256 expectedRR = (elapsed * rateScaled) / 1e18;

        // Sanity via getter
        uint256 viewRR = revShareModule.earnedByTakadao(revenueReceiver);
        assertEq(viewRR, expectedRR, "takadao earned view mismatch (global)");

        // Claim is executed by REVENUE_CLAIMER, funds go to revenueReceiver
        uint256 pre = usdc.balanceOf(revenueReceiver);
        vm.prank(revenueClaimer);
        uint256 claimed = revShareModule.claimRevenueShare();
        assertEq(claimed, expectedRR, "takadao claimed mismatch (global)");
        assertEq(
            usdc.balanceOf(revenueReceiver),
            pre + expectedRR,
            "USDC not paid to revenueReceiver"
        );
    }

    /// Two deposits with carry-over: piecewise accrual matches math (pioneers)
    function testRevShareModule_pioneerClaimMathMatchesTwoDepositsCarryover() public {
        _setRewardsDuration365();

        // Fix denominator
        vm.store(address(nft), bytes32(uint256(2)), bytes32(uint256(1_500)));

        uint256 dur = revShareModule.rewardsDuration(); // 31_536_000
        uint256 totalSupply = 1_500;

        // First deposit D1 = 20,000
        uint256 D1 = 20_000e6;
        uint256 pShare1 = (D1 * 75) / 100;
        uint256 r1Scaled = (pShare1 * 1e18) / dur;
        _fundAndApprove(module, D1);
        _notify(module, D1);

        // Let t1 pass
        uint256 t1 = 10 days; // 864,000
        uint256 d1Scaled = (t1 * r1Scaled) / totalSupply;
        _warp(t1);

        // Mid-stream deposit D2 = 12,000
        uint256 D2 = 12_000e6;
        uint256 pShare2 = (D2 * 75) / 100;
        // carry-over leftover = (remaining * r1)
        uint256 remaining = revShareModule.periodFinish() - block.timestamp;
        uint256 leftoverScaled = remaining * r1Scaled;
        // new rate r2 = floor((pShare2 * 1e18 + leftoverScaled) / dur)
        uint256 r2Scaled = (pShare2 * 1e18 + leftoverScaled) / dur;

        _fundAndApprove(module, D2);
        _notify(module, D2);

        // After notify, the stream resets (periodFinish := now + dur)
        // Let t2 pass
        uint256 t2 = 5 days; // 432_000
        uint256 d2Scaled = (t2 * r2Scaled) / totalSupply;
        _warp(t2);

        // Alice has 50 NFTs
        uint256 expectedAlice = (50 * (d1Scaled + d2Scaled)) / 1e18;

        // Check via view then claim
        uint256 viewAlice = revShareModule.earnedByPioneers(alice);
        assertEq(viewAlice, expectedAlice, "two-deposit earned view mismatch");

        uint256 pre = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = revShareModule.claimRevenueShare();
        assertEq(claimed, expectedAlice, "two-deposit claimed mismatch");
        assertEq(usdc.balanceOf(alice), pre + expectedAlice, "USDC not received by alice");
    }

    /// No pioneers accrual when totalSupply == 0 (global update short-circuits the 75% path)
    /// Note: Takadao still accrues globally; this test checks the 75% path only.
    function testRevShareModule_noAccrualWhenTotalSupplyZero() public {
        _setRewardsDuration365();

        // Force denominator to zero BEFORE starting a stream
        vm.store(address(nft), bytes32(uint256(2)), bytes32(uint256(0)));

        uint256 amount = 10_000e6;
        _fundAndApprove(module, amount);
        _notify(module, amount);

        _warp(7 days);

        // Pioneers earned should be zero because supply==0 for the 75% path
        assertEq(revShareModule.earnedByPioneers(alice), 0, "should earn 0 with totalSupply==0");

        vm.prank(alice);
        assertEq(revShareModule.claimRevenueShare(), 0, "claim should be 0 with totalSupply==0");
    }

    /// Accrual caps at periodFinish (pioneer claim after stream end)
    function testRevShareModule_pioneerClaimCapsAtPeriodFinish() public {
        _setRewardsDuration365();

        uint256 amount = 30_000e6;
        _fundAndApprove(module, amount);
        _notify(module, amount);

        // Fix denominator
        vm.store(address(nft), bytes32(uint256(2)), bytes32(uint256(1_500)));

        // Warp *beyond* periodFinish
        uint256 pf = revShareModule.periodFinish();
        _warp((pf - block.timestamp) + 10 days); // 10 days past finish

        // --- Expected math ---
        // Accrual caps at full duration; do fixed-point steps to match contract rounding
        uint256 dur = revShareModule.rewardsDuration();
        uint256 totalSupply = 1_500;
        uint256 balance = 50;

        uint256 pShare = (amount * 75) / 100;
        uint256 rScaled = (pShare * 1e18) / dur; // floor
        uint256 fullDurPerNftScaled = (dur * rScaled) / totalSupply; // floor

        uint256 expectedAlice = (balance * fullDurPerNftScaled) / 1e18;

        // Check via view then claim
        uint256 viewAlice = revShareModule.earnedByPioneers(alice);
        assertEq(viewAlice, expectedAlice, "cap-at-finish earned mismatch");

        uint256 pre = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = revShareModule.claimRevenueShare();
        assertEq(claimed, expectedAlice, "cap-at-finish claim mismatch");
        assertEq(usdc.balanceOf(alice), pre + expectedAlice, "USDC not received by alice");
    }

    /// Former pioneer can claim accrual after transferring away all NFTs.
    /// Relies on the NFT's transfer hook calling module.updateRevenue(holder).
    function testRevShareModule_formerPioneerCanClaimAfterSellingAll() public {
        _setRewardsDuration365();

        // Start a stream
        uint256 amount = 20_000e6;
        _fundAndApprove(module, amount);
        _notify(module, amount);

        // Mint one NFT to a fresh holder ("former"), then accrue time
        address former = makeAddr("formerPioneer");
        uint256 t0 = nft.totalSupply(); // <-- tokenId that WILL be minted
        vm.startPrank(nft.owner());
        nft.setPeriodTransferLock(1 days);
        nft.mint(former);
        vm.stopPrank();

        uint256 tokenId = t0; // <-- correct id (mint() uses tokenId = totalSupply BEFORE increment)
        assertEq(nft.ownerOf(tokenId), former, "former should own freshly minted token");
        assertEq(nft.balanceOf(former), 1);

        // Accrue some time while former holds the NFT (past lock)
        _warp(10 days);

        // Transfer away the only NFT — hook should snapshot former's accrual
        vm.prank(former);
        nft.transfer(bob, tokenId);

        assertEq(nft.balanceOf(former), 0, "former should hold 0 after transfer");

        // Former should have an unpaid bucket recorded at transfer time
        uint256 owed = revShareModule.earnedByPioneers(former);
        console2.log("Former pioneer owed (pre-claim):", owed);
        assertGt(owed, 0, "former should have unpaid accrual recorded on transfer");

        // Claim succeeds and pays former
        uint256 pre = usdc.balanceOf(former);
        vm.prank(former);
        uint256 claimed = revShareModule.claimRevenueShare();
        assertEq(claimed, owed, "claimed must equal owed snapshot");
        assertEq(usdc.balanceOf(former), pre + owed, "USDC not paid to former pioneer");

        // Subsequent immediate claim returns 0
        vm.prank(former);
        vm.expectRevert();
        revShareModule.claimRevenueShare();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setRewardsDuration365() internal {
        // periodFinish == 0 at this point (we haven't started a stream),
        // so it's legal to set the duration.
        vm.prank(takadao);
        revShareModule.setRewardsDuration(365 days); // 31,536,000 seconds
    }

    function _fundAndApprove(address from, uint256 amount) internal {
        deal(address(usdc), from, amount);
        vm.startPrank(from);
        usdc.approve(address(revShareModule), amount);
        vm.stopPrank();
    }

    function _notify(address from, uint256 amount) internal {
        vm.prank(from);
        revShareModule.notifyNewRevenue(amount);
    }

    function _warp(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
    }
}
