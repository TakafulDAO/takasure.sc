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

contract NotifyClaimInteraction_RevShareModuleTest is Test {
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

        // fund + notify (first stream; duration assumed 365 days)
        deal(address(usdc), module, 50_000e6); // 50,000 USDC

        // force totalSupply to a known value
        uint256 forcedTotalSupply = 1_500;
        vm.store(
            address(nft),
            bytes32(uint256(2)), // slot index for totalSupply
            bytes32(forcedTotalSupply)
        );
    }

    // Single stream -> pioneer claim math matches exactly
    function testRevShareModule_pioneerClaimMathMatchesSingleStream() public {
        _setRewardsDuration365();

        // Start stream with 50,000 USDC
        uint256 amount = 50_000e6;
        _fundAndApprove(module, amount);
        _notify(module, amount);

        // Force a known totalSupply (denominator) to 1,500 as in the setUp fixture
        vm.store(address(nft), bytes32(uint256(2)), bytes32(uint256(1_500)));

        // Let time pass
        uint256 elapsed = 10 days; // 864,000 seconds
        _warp(elapsed);

        // --- Expected math (pioneers stream) ---
        // PIONEERS share = 75% of amount
        uint256 pShare = (amount * 75) / 100; // 37,500e6

        // rewardsDuration = 365 days = 31,536,000 seconds
        uint256 dur = revShareModule.rewardsDuration(); // 31_536_000

        // rewardRateP = floor(pShare / dur)
        uint256 rewardRateP = pShare / dur;

        // revenuePerNft delta = elapsed * rewardRateP * PRECISION / totalSupply
        // PRECISION = 1e6
        uint256 PRECISION = 1e6;
        uint256 totalSupply = 1_500;
        uint256 deltaPerNft = (elapsed * rewardRateP * PRECISION) / totalSupply;

        // alice has 50 NFTs -> expected earned = 50 * deltaPerNft / PRECISION
        uint256 expectedAlice = (50 * deltaPerNft) / PRECISION;

        // Sanity: view getter should match our math
        uint256 earnedView = revShareModule.earnedPioneers(alice);
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

    // Takadao claim (25% stream) when revenueReceiver HOLDS NFTs
    function testRevShareModule_takadaoClaimMathMatchesWithRRBalance() public {
        _setRewardsDuration365();

        // Give revenueReceiver some NFTs so it accrues from 25% stream
        vm.prank(nft.owner());
        nft.batchMint(revenueReceiver, 10);

        uint256 amount = 50_000e6;
        _fundAndApprove(module, amount);
        _notify(module, amount);

        // Fix denominator
        vm.store(address(nft), bytes32(uint256(2)), bytes32(uint256(1_500)));

        uint256 elapsed = 5 days; // 432,000 sec
        _warp(elapsed);

        // --- Expected math (takadao stream) ---
        // TAKADAO share = 25% of amount
        uint256 tShare = (amount * 25) / 100; // 12,500e6
        uint256 dur = revShareModule.rewardsDuration(); // 31_536_000
        uint256 rewardRateT = tShare / dur; // floor division

        // per-NFT delta for takadao stream:
        // delta = elapsed * rewardRateT * PRECISION / totalSupply
        uint256 PRECISION = 1e6;
        uint256 totalSupply = 1_500;
        uint256 deltaPerNft = (elapsed * rewardRateT * PRECISION) / totalSupply;

        // revenueReceiver has 10 NFTs
        uint256 expectedRR = (10 * deltaPerNft) / PRECISION;

        // Sanity via getter
        uint256 viewRR = revShareModule.earnedTakadao(revenueReceiver);
        assertEq(viewRR, expectedRR, "takadao earned view mismatch");

        // Claim is executed by REVENUE_CLAIMER, funds go to revenueReceiver
        uint256 pre = usdc.balanceOf(revenueReceiver);
        vm.prank(revenueClaimer);
        uint256 claimed = revShareModule.claimRevenueShare();
        assertEq(claimed, expectedRR, "takadao claimed mismatch");
        assertEq(
            usdc.balanceOf(revenueReceiver),
            pre + expectedRR,
            "USDC not paid to revenueReceiver"
        );
    }

    // Two deposits with carry-over: piecewise accrual matches math
    function testRevShareModule_pioneerClaimMathMatchesTwoDepositsCarryover() public {
        _setRewardsDuration365();

        // Fix denominator
        vm.store(address(nft), bytes32(uint256(2)), bytes32(uint256(1_500)));

        uint256 dur = revShareModule.rewardsDuration(); // 31_536_000
        uint256 PRECISION = 1e6;
        uint256 totalSupply = 1_500;

        // First deposit D1 = 20,000
        uint256 D1 = 20_000e6;
        _fundAndApprove(module, D1);
        _notify(module, D1);

        // Let t1 pass
        uint256 t1 = 10 days; // 864,000
        _warp(t1);

        // For interval 1:
        uint256 pShare1 = (D1 * 75) / 100; // 15,000e6
        uint256 r1 = pShare1 / dur; // pioneers rate1
        uint256 d1 = (t1 * r1 * PRECISION) / totalSupply; // per-NFT accumulator increment for interval 1

        // Mid-stream deposit D2 = 12,000
        uint256 D2 = 12_000e6;
        // carry-over leftover = (remaining * r1)
        uint256 remaining = revShareModule.periodFinish() - block.timestamp;
        uint256 leftover = remaining * r1;
        // new rate r2 = (pShare2 + leftover) / dur
        uint256 pShare2 = (D2 * 75) / 100; // 9,000e6
        uint256 r2 = (pShare2 + leftover) / dur;

        _fundAndApprove(module, D2);
        _notify(module, D2);

        // After notify, the stream resets (periodFinish := now + dur)
        // Let t2 pass
        uint256 t2 = 5 days; // 432,000
        _warp(t2);

        // Interval 2 increment:
        uint256 d2 = (t2 * r2 * PRECISION) / totalSupply;

        // Alice has 50 NFTs
        uint256 expectedAlice = (50 * (d1 + d2)) / PRECISION;

        // Check via view then claim
        uint256 viewAlice = revShareModule.earnedPioneers(alice);
        assertEq(viewAlice, expectedAlice, "two-deposit earned view mismatch");

        uint256 pre = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = revShareModule.claimRevenueShare();
        assertEq(claimed, expectedAlice, "two-deposit claimed mismatch");
        assertEq(usdc.balanceOf(alice), pre + expectedAlice, "USDC not received by alice");
    }

    // No accrual when totalSupply == 0 (global update short-circuits)
    function testRevShareModule_noAccrualWhenTotalSupplyZero() public {
        _setRewardsDuration365();

        // Force denominator to zero BEFORE starting a stream
        vm.store(address(nft), bytes32(uint256(2)), bytes32(uint256(0)));

        uint256 amount = 10_000e6;
        _fundAndApprove(module, amount);
        _notify(module, amount);

        _warp(7 days);

        // All earned should be zero because _updateGlobal sees supply==0
        assertEq(revShareModule.earnedPioneers(alice), 0, "should earn 0 with totalSupply==0");

        vm.prank(alice);
        assertEq(revShareModule.claimRevenueShare(), 0, "claim should be 0 with totalSupply==0");
    }

    // Accrual caps at periodFinish (claim after stream end)
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
        // Only accrues up to dur seconds, not past
        uint256 dur = revShareModule.rewardsDuration(); // 31,536,000
        uint256 pShare = (amount * 75) / 100; // 22,500e6
        uint256 r = pShare / dur;

        uint256 PRECISION = 1e6;
        uint256 totalSupply = 1_500;

        // Per-NFT increment capped at full duration
        uint256 deltaPerNft = (dur * r * PRECISION) / totalSupply;

        // Alice has 50 NFTs
        uint256 expectedAlice = (50 * deltaPerNft) / PRECISION;

        // Check via view then claim
        uint256 viewAlice = revShareModule.earnedPioneers(alice);
        assertEq(viewAlice, expectedAlice, "cap-at-finish earned mismatch");

        uint256 pre = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = revShareModule.claimRevenueShare();
        assertEq(claimed, expectedAlice, "cap-at-finish claim mismatch");
        assertEq(usdc.balanceOf(alice), pre + expectedAlice, "USDC not received by alice");
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
