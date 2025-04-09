// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract RevShareModuleTest is Test {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    RevShareModule revShareModule;
    IUSDC usdc;
    address admin;
    address takadao;
    address minter;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address revShareModuleAddress;
    address couponBuyer = makeAddr("couponBuyer");
    address couponJoiner = makeAddr("couponJoiner");
    address couponJoinerMax = makeAddr("couponJoinerMax");
    address joiner = makeAddr("joiner");
    address joinerMax = makeAddr("joinerMax");
    address joinerMaxNoKyc = makeAddr("joinerMaxNoKyc");
    uint256 public constant NFT_PRICE = 250e6; // 250 USDC
    uint256 public constant NO_MAX_CONTRIBUTION = 25e6; // 25 USDC
    uint256 public constant NO_MAX_COUPON = 200e6; // 200 USDC
    uint256 public constant YEAR = 365 days;

    event OnRevShareNFTMinted(address indexed member, uint256 tokenId);
    event OnRevShareNFTActivated(address indexed couponBuyer, uint256 tokenId);
    event OnCouponAmountByBuyerIncreased(address indexed buyer, uint256 amount);
    event OnCouponAmountRedeemedByBuyerIncreased(address indexed buyer, uint256 amount);
    event OnRevenueClaimed(address indexed member, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            ,
            ,
            takasureReserveProxy,
            ,
            ,
            ,
            ,
            revShareModuleAddress,
            ,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        revShareModule = RevShareModule(revShareModuleAddress);

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        minter = config.kycProvider;
        takadao = config.takadaoOperator;

        deal(address(usdc), revShareModuleAddress, 100000000); // 100 USDC

        vm.warp(1 days);
        vm.roll(block.number + 1);
    }

    /*//////////////////////////////////////////////////////////////
                                  INIT
    //////////////////////////////////////////////////////////////*/

    function testRevShareModule_initialValues() public view {
        assertEq(revShareModule.NFT_PRICE(), NFT_PRICE);
        assertEq(revShareModule.MAX_SUPPLY(), 18_000);
        assertEq(revShareModule.lastUpdatedTimestamp(), 1);
        assertEq(revShareModule.totalSupply(), 0);
        assert(revShareModule.hasRole(revShareModule.MINTER_ROLE(), minter));
        assert(revShareModule.hasRole(0x00, takadao));
        assert(revShareModule.hasRole(keccak256("TAKADAO_OPERATOR"), takadao));
    }

    /*//////////////////////////////////////////////////////////////
                            INCREASE COUPON
    //////////////////////////////////////////////////////////////*/

    function testRevShareModule_increaseCouponAmountByBuyerRevertsIfCallerIsWrong() public {
        vm.prank(joinerMaxNoKyc);
        vm.expectRevert();
        revShareModule.increaseCouponAmountByBuyer(couponBuyer, 5 * NFT_PRICE);
    }

    function testRevShareModule_increaseCouponAmountByBuyerRevertsIfBuyerIsAddressZero() public {
        vm.prank(minter);
        vm.expectRevert();
        revShareModule.increaseCouponAmountByBuyer(address(0), 5 * NFT_PRICE);
    }

    function testRevShareModule_increaseCouponAmountByBuyerRevertsIfCouponIsZero() public {
        vm.prank(minter);
        vm.expectRevert(RevShareModule.RevShareModule__NotZeroAmount.selector);
        revShareModule.increaseCouponAmountByBuyer(couponBuyer, 0);
    }

    function testRevShareModule_increaseCouponAmountByBuyer() public {
        assertEq(revShareModule.couponAmountsByBuyer(couponBuyer), 0);

        uint256 amountToIncrease = (5 * NFT_PRICE) + 100e6;

        vm.prank(minter);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnCouponAmountByBuyerIncreased(couponBuyer, amountToIncrease); // 1350USDC
        revShareModule.increaseCouponAmountByBuyer(couponBuyer, amountToIncrease);

        assertEq(revShareModule.couponAmountsByBuyer(couponBuyer), amountToIncrease);
    }

    modifier increaseCouponAmountByBuyer() {
        vm.startPrank(minter);
        revShareModule.increaseCouponAmountByBuyer(couponBuyer, (5 * NFT_PRICE) + 100e6);
        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              SINGLE MINT
    //////////////////////////////////////////////////////////////*/

    function testRevShareModule_mintMustRevertIfMemberIsAddressZero() public {
        vm.prank(minter);
        vm.expectRevert();
        revShareModule.mintOrActivate(
            RevShareModule.Operation.SINGLE_MINT,
            address(0),
            address(0),
            0
        );
    }

    function testRevShareModule_mintSingleNft() public {
        uint256 lastUpdatedTimestamp_initialState = revShareModule.lastUpdatedTimestamp();
        uint256 latestTokenId_initialState = revShareModule.totalSupply();
        bool isNftActive_initialState = revShareModule.isNFTActive(latestTokenId_initialState + 1);
        bool joinerClaimed_initialState = revShareModule.claimedNFTs(joinerMax);
        uint256 joinerBalance_initialState = revShareModule.balanceOf(joinerMax);
        uint256 revenuePerNFTOwned_initialState = revShareModule.revenuePerNFTOwned();
        uint256 userRevenue_initialState = revShareModule.revenues(joinerMax);
        uint256 userRevenuePerNftPaid_initialState = revShareModule.userRevenuePerNFTPaid(
            joinerMax
        );

        vm.prank(minter);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnRevShareNFTMinted(joinerMax, latestTokenId_initialState + 1);
        revShareModule.mintOrActivate(
            RevShareModule.Operation.SINGLE_MINT,
            joinerMax,
            address(0),
            0
        );

        assert(revShareModule.lastUpdatedTimestamp() > lastUpdatedTimestamp_initialState);
        assertEq(revShareModule.totalSupply(), latestTokenId_initialState + 1);
        assert(!isNftActive_initialState);
        assert(revShareModule.isNFTActive(revShareModule.totalSupply()));
        assert(!joinerClaimed_initialState);
        assert(revShareModule.claimedNFTs(joinerMax));
        assertEq(joinerBalance_initialState, 0);
        assertEq(revShareModule.balanceOf(joinerMax), 1);
        assertEq(revShareModule.tokenOfOwnerByIndex(joinerMax, 0), 1);
        assertEq(userRevenue_initialState, 0);
        // assertEq(revShareModule.revenues(joinerMax), 0); // todo: check this
        assertEq(revenuePerNFTOwned_initialState, 0);
        assertApproxEqAbs(revShareModule.revenuePerNFTOwned(), 48e5, 100);
        assertEq(userRevenuePerNftPaid_initialState, 0);
        assertApproxEqAbs(revShareModule.userRevenuePerNFTPaid(joinerMax), 48e5, 100);
    }

    modifier singleMint() {
        vm.prank(minter);
        revShareModule.mintOrActivate(
            RevShareModule.Operation.SINGLE_MINT,
            joinerMax,
            address(0),
            0
        );
        _;
    }

    function testRevShareModule_mintRevertsIfAlreadyClaimed() public singleMint {
        vm.prank(minter);
        vm.expectRevert(RevShareModule.RevShareModule__NotAllowedToMint.selector);
        revShareModule.mintOrActivate(
            RevShareModule.Operation.SINGLE_MINT,
            joinerMax,
            address(0),
            0
        );
    }

    // /*//////////////////////////////////////////////////////////////
    //                            BATCH MINT
    // //////////////////////////////////////////////////////////////*/

    // function testRevShareModule_batchMintRevertIfNoCouponRedeemed() public {
    //     vm.prank(couponBuyer);
    //     vm.expectRevert(RevShareModule.RevShareModule__NotAllowedToMint.selector);
    //     revShareModule.batchMint();
    // }

    // function testRevShareModule_batchMint() public increaseCouponAmountByBuyer {
    //     uint256 latestTokenId_initialState = revShareModule.totalSupply();
    //     bool isNft1Active_initialState = revShareModule.isNFTActive(1);
    //     bool isNft2Active_initialState = revShareModule.isNFTActive(2);
    //     bool isNft3Active_initialState = revShareModule.isNFTActive(3);
    //     bool isNft4Active_initialState = revShareModule.isNFTActive(4);
    //     bool isNft5Active_initialState = revShareModule.isNFTActive(5);
    //     uint256 couponBuyerBalance_initialState = revShareModule.balanceOf(couponBuyer);

    //     vm.prank(couponBuyer);

    //     vm.expectEmit(true, false, false, false, address(revShareModule));
    //     emit OnRevShareNFTMinted(couponBuyer, 1);
    //     vm.expectEmit(true, false, false, false, address(revShareModule));
    //     emit OnRevShareNFTMinted(couponBuyer, 2);
    //     vm.expectEmit(true, false, false, false, address(revShareModule));
    //     emit OnRevShareNFTMinted(couponBuyer, 3);
    //     vm.expectEmit(true, false, false, false, address(revShareModule));
    //     emit OnRevShareNFTMinted(couponBuyer, 4);
    //     vm.expectEmit(true, false, false, false, address(revShareModule));
    //     emit OnRevShareNFTMinted(couponBuyer, 5);

    //     revShareModule.batchMint();

    //     assertEq(revShareModule.totalSupply(), latestTokenId_initialState + 5);
    //     assert(!isNft1Active_initialState);
    //     assert(!isNft2Active_initialState);
    //     assert(!isNft3Active_initialState);
    //     assert(!isNft4Active_initialState);
    //     assert(!isNft5Active_initialState);
    //     assert(!revShareModule.isNFTActive(1));
    //     assert(!revShareModule.isNFTActive(2));
    //     assert(!revShareModule.isNFTActive(3));
    //     assert(!revShareModule.isNFTActive(4));
    //     assert(!revShareModule.isNFTActive(5));
    //     assertEq(couponBuyerBalance_initialState, 0);
    //     assertEq(revShareModule.balanceOf(couponBuyer), 5);
    // }

    // modifier batchMint() {
    //     vm.prank(couponBuyer);
    //     revShareModule.batchMint();
    //     _;
    // }

    // /*//////////////////////////////////////////////////////////////
    //                             ACTIVATE
    // //////////////////////////////////////////////////////////////*/

    // function testRevShareModule_activateTokenRevertsIfNoCouponIsRedeemed()
    //     public
    //     increaseCouponAmountByBuyer
    //     batchMint
    // {
    //     vm.prank(couponBuyer);
    //     vm.expectRevert(RevShareModule.RevShareModule__NotEnoughRedeemedAmount.selector);
    //     revShareModule.activateNFT();
    // }

    // function testRevShareModule_activateToken()
    //     public
    //     increaseCouponAmountByBuyer
    //     batchMint
    //     increaseCouponRedeemedAmountByBuyer
    // {
    //     uint256 lastUpdatedTimestamp_initialState = revShareModule.lastUpdatedTimestamp();
    //     bool isNftActive_initialState = revShareModule.isNFTActive(1);
    //     uint256 userRevenue_initialState = revShareModule.revenues(couponBuyer);
    //     uint256 revenuePerNFTOwned_initialState = revShareModule.revenuePerNFTOwned();
    //     uint256 userRevenuePerNftPaid_initialState = revShareModule.userRevenuePerNFTPaid(
    //         couponBuyer
    //     );

    //     vm.prank(couponBuyer);
    //     vm.expectEmit(true, false, false, false, address(revShareModule));
    //     emit OnRevShareNFTActivated(couponBuyer, 1);
    //     revShareModule.activateNFT();

    //     assert(revShareModule.lastUpdatedTimestamp() > lastUpdatedTimestamp_initialState);
    //     assert(!isNftActive_initialState);
    //     assert(revShareModule.isNFTActive(1));
    //     assertEq(userRevenue_initialState, 0);
    //     assertEq(revShareModule.revenues(couponBuyer), 0);
    //     assertEq(revenuePerNFTOwned_initialState, 0);
    //     assertApproxEqAbs(revShareModule.revenuePerNFTOwned(), 48e5, 100);
    //     assertEq(userRevenuePerNftPaid_initialState, 0);
    //     assertApproxEqAbs(revShareModule.userRevenuePerNFTPaid(couponBuyer), 48e5, 100);
    // }

    // modifier activateNft() {
    //     vm.prank(couponBuyer);
    //     revShareModule.activateNFT();
    //     _;
    // }

    // /*//////////////////////////////////////////////////////////////
    //                            TRANSFERS
    // //////////////////////////////////////////////////////////////*/

    // function testRevShareModule_transferInactiveNftReverts()
    //     public
    //     increaseCouponAmountByBuyer
    //     batchMint
    // {
    //     vm.prank(couponBuyer);
    //     vm.expectRevert(RevShareModule.RevShareModule__NotActiveToken.selector);
    //     revShareModule.transfer(joinerMax, 1);
    // }

    // function testRevShareModule_transferFromInactiveNftReverts()
    //     public
    //     increaseCouponAmountByBuyer
    //     batchMint
    // {
    //     vm.prank(couponBuyer);
    //     revShareModule.setApprovalForAll(revShareModuleAddress, true);

    //     vm.prank(revShareModuleAddress);
    //     vm.expectRevert(RevShareModule.RevShareModule__NotActiveToken.selector);
    //     revShareModule.transferFrom(couponBuyer, joinerMax, 1);
    // }

    // function testRevShareModule_transferNft()
    //     public
    //     increaseCouponAmountByBuyer
    //     batchMint
    //     increaseCouponRedeemedAmountByBuyer
    //     activateNft
    // {
    //     assertEq(revShareModule.balanceOf(couponBuyer), 5);
    //     assertEq(revShareModule.balanceOf(joinerMax), 0);

    //     vm.prank(couponBuyer);
    //     revShareModule.transfer(joinerMax, 1);

    //     assertEq(revShareModule.balanceOf(couponBuyer), 4);
    //     assertEq(revShareModule.balanceOf(joinerMax), 1);
    // }

    // function testRevShareModule_transferFromNft()
    //     public
    //     increaseCouponAmountByBuyer
    //     batchMint
    //     increaseCouponRedeemedAmountByBuyer
    //     activateNft
    // {
    //     assertEq(revShareModule.balanceOf(couponBuyer), 5);
    //     assertEq(revShareModule.balanceOf(joinerMax), 0);

    //     vm.prank(couponBuyer);
    //     revShareModule.setApprovalForAll(revShareModuleAddress, true);

    //     vm.prank(revShareModuleAddress);
    //     revShareModule.transferFrom(couponBuyer, joinerMax, 1);

    //     assertEq(revShareModule.balanceOf(couponBuyer), 4);
    //     assertEq(revShareModule.balanceOf(joinerMax), 1);
    // }

    // /*//////////////////////////////////////////////////////////////
    //                          CLAIM REVENUE
    // //////////////////////////////////////////////////////////////*/

    // function testRevShareModule_claimRevenueRevertsIfNoToken() public {
    //     vm.prank(joinerMax);
    //     vm.expectRevert(RevShareModule.RevShareModule__NotNFTOwner.selector);
    //     revShareModule.claimRevenue();
    // }

    // function testRevShareModule_claimRevenueRevertsIfNoRevenue() public mint {
    //     vm.prank(joinerMax);
    //     vm.expectRevert(RevShareModule.RevShareModule__NoRevenueToClaim.selector);
    //     revShareModule.claimRevenue();

    //     assertEq(revShareModule.getRevenueEarnedByUser(joinerMax), 0);
    // }

    // function testRevShareModule_claimRevenueSuccessfully() public mint {
    //     uint256 initialRevenuePerNFT = revShareModule.getRevenuePerNFT();
    //     uint256 initialUserRevenue = revShareModule.revenues(joinerMax);
    //     uint256 initialRevenueEarnedByUser = revShareModule.getRevenueEarnedByUser(joinerMax);
    //     uint256 initialUserBalance = usdc.balanceOf(joinerMax);
    //     uint256 initialContractBalance = usdc.balanceOf(revShareModuleAddress);
    //     uint256 expectedTransferRevenue = 4;

    //     vm.warp(2 days);
    //     vm.roll(block.number + 1);

    //     vm.prank(joinerMax);

    //     vm.expectEmit(true, true, false, false, address(usdc));
    //     emit Transfer(address(revShareModule), joinerMax, expectedTransferRevenue);

    //     vm.expectEmit(true, false, false, false, address(revShareModule));
    //     emit OnRevenueClaimed(joinerMax, expectedTransferRevenue);

    //     revShareModule.claimRevenue();

    //     uint256 finalRevenuePerNFT = revShareModule.getRevenuePerNFT();
    //     uint256 finalUserRevenue = revShareModule.revenues(joinerMax);
    //     uint256 finalRevenueEarnedByUser = revShareModule.getRevenueEarnedByUser(joinerMax);
    //     uint256 finalUserBalance = usdc.balanceOf(joinerMax);
    //     uint256 finalContractBalance = usdc.balanceOf(revShareModuleAddress);

    //     assertEq(finalContractBalance, initialContractBalance - expectedTransferRevenue);
    //     assertEq(finalUserBalance, initialUserBalance + expectedTransferRevenue);
    // }

    // modifier claimRevenue() {
    //     vm.warp(2 days);
    //     vm.roll(block.number + 1);

    //     vm.prank(joinerMax);
    //     revShareModule.claimRevenue();
    //     _;
    // }

    // function testRevShareModule_claimRevenueRevertsIfClaimedAndNoTimePassed()
    //     public
    //     mint
    //     claimRevenue
    // {
    //     vm.prank(joinerMax);
    //     vm.expectRevert(RevShareModule.RevShareModule__NoRevenueToClaim.selector);
    //     revShareModule.claimRevenue();
    // }

    // function testRevShareModule_claimRevenueAfterSomeTime() public mint claimRevenue {
    //     vm.warp(3 days);
    //     vm.roll(block.number + 1);

    //     vm.prank(joinerMax);
    //     revShareModule.claimRevenue();
    // }

    // function testRevShareModule_claimRevenueMoreThanOneActive()
    //     public
    //     mint
    //     increaseCouponAmountByBuyer
    //     batchMint
    //     increaseCouponRedeemedAmountByBuyer
    //     activateNft
    // {
    //     uint256 expectedTransferRevenue = 4e6;

    //     vm.warp(2 days);
    //     vm.roll(block.number + 1);

    //     vm.startPrank(joinerMax);
    //     // Can claim
    //     vm.expectEmit(true, true, false, false, address(usdc));
    //     emit Transfer(address(revShareModule), joinerMax, expectedTransferRevenue);

    //     vm.expectEmit(true, false, false, false, address(revShareModule));
    //     emit OnRevenueClaimed(joinerMax, expectedTransferRevenue);

    //     revShareModule.claimRevenue();

    //     // But can not claim again if no time passed
    //     vm.expectRevert(RevShareModule.RevShareModule__NoRevenueToClaim.selector);
    //     revShareModule.claimRevenue();
    //     vm.stopPrank();

    //     // But others can claim
    //     vm.prank(couponBuyer);
    //     vm.expectEmit(true, true, false, false, address(usdc));
    //     emit Transfer(address(revShareModule), couponBuyer, expectedTransferRevenue);

    //     vm.expectEmit(true, false, false, false, address(revShareModule));
    //     emit OnRevenueClaimed(couponBuyer, expectedTransferRevenue);
    //     revShareModule.claimRevenue();

    //     vm.prank(takadao);
    //     revShareModule.claimRevenue();
    // }
}
