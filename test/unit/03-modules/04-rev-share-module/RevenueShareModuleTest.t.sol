// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract RevShareModuleTest is Test {
    TestDeployProtocol deployer;
    HelperConfig helperConfig;
    RevShareModule revShareModule;
    IUSDC usdc;
    address takadao;
    address minter;
    address contributionTokenAddress;
    address revShareModuleAddress;
    address couponBuyer = makeAddr("couponBuyer");
    address joinerMax = makeAddr("joinerMax");
    uint256 public constant NFT_PRICE = 250e6; // 250 USDC

    event OnRevShareNFTMinted(address indexed member, uint256 tokenId);
    event OnBatchRevShareNFTMinted(
        address indexed couponBuyer,
        uint256 initialTokenId,
        uint256 lastTokenId
    );
    event OnRevShareNFTActivated(address indexed couponBuyer, uint256 tokenId);
    event OnCouponAmountByBuyerIncreased(address indexed buyer, uint256 amount);
    event OnCouponAmountRedeemedByBuyerIncreased(address indexed buyer, uint256 amount);
    event OnRevenueClaimed(address indexed member, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 value);

    function setUp() public {
        deployer = new TestDeployProtocol();
        (, , , , , , , revShareModuleAddress, , contributionTokenAddress, , helperConfig) = deployer
            .run();

        revShareModule = RevShareModule(revShareModuleAddress);

        usdc = IUSDC(contributionTokenAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

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
        assertEq(revShareModule.totalSupply(), 9180);
        assert(revShareModule.hasRole(revShareModule.MINTER_ROLE(), minter));
        assert(revShareModule.hasRole(0x00, takadao));
        assert(revShareModule.hasRole(keccak256("TAKADAO_OPERATOR"), takadao));
    }

    /*//////////////////////////////////////////////////////////////
                            INCREASE COUPON
    //////////////////////////////////////////////////////////////*/

    function testRevShareModule_increaseCouponAmountByBuyerRevertsIfCallerIsWrong() public {
        vm.prank(joinerMax);
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
        bool isActive_initialState = revShareModule.isActive(latestTokenId_initialState + 1);
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
        assert(!isActive_initialState);
        assert(revShareModule.isActive(revShareModule.totalSupply()));
        assert(!joinerClaimed_initialState);
        assert(revShareModule.claimedNFTs(joinerMax));
        assertEq(joinerBalance_initialState, 0);
        assertEq(revShareModule.balanceOf(joinerMax), 1);
        assertEq(revShareModule.tokenOfOwnerByIndex(joinerMax, 0), 9181);
        assertEq(userRevenue_initialState, 0);
        assertEq(revShareModule.revenues(joinerMax), 0);
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

    /*//////////////////////////////////////////////////////////////
                               BATCH MINT
    //////////////////////////////////////////////////////////////*/

    function testRevShareModule_batchMintRevertIfIsAddressZero() public {
        vm.prank(minter);
        vm.expectRevert();
        revShareModule.batchMint(address(0), NFT_PRICE);
    }

    function testRevShareModule_batchMintRevertIfThereIsNothingToMint() public {
        vm.prank(minter);
        vm.expectRevert(RevShareModule.RevShareModule__NotZeroAmount.selector);
        revShareModule.batchMint(couponBuyer, 0);
    }

    function testRevShareModule_batchMintIncreaseCouponAmountIfNotEnoughToBuy() public {
        assertEq(revShareModule.balanceOf(couponBuyer), 0);
        assertEq(revShareModule.couponAmountsByBuyer(couponBuyer), 0);

        vm.prank(minter);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnCouponAmountByBuyerIncreased(couponBuyer, 100e6);
        revShareModule.batchMint(couponBuyer, 100e6);

        assertEq(revShareModule.couponAmountsByBuyer(couponBuyer), 100e6);
        assertEq(revShareModule.balanceOf(couponBuyer), 0);

        vm.prank(minter);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnCouponAmountByBuyerIncreased(couponBuyer, 50e6);
        revShareModule.batchMint(couponBuyer, 50e6);

        assertEq(revShareModule.couponAmountsByBuyer(couponBuyer), 150e6);
        assertEq(revShareModule.balanceOf(couponBuyer), 0);
    }

    function testRevShareModule_batchMintTokens() public increaseCouponAmountByBuyer {
        uint256 amountRedeemed = (5 * NFT_PRICE) + 100e6; //
        assertEq(revShareModule.balanceOf(couponBuyer), 0);
        assertEq(revShareModule.couponAmountsByBuyer(couponBuyer), amountRedeemed);

        vm.prank(minter);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnBatchRevShareNFTMinted(couponBuyer, 9181, 9185);
        revShareModule.batchMint(couponBuyer, 0);

        assertEq(revShareModule.couponAmountsByBuyer(couponBuyer), 100e6);
        assertEq(revShareModule.balanceOf(couponBuyer), 5);

        vm.prank(minter);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnBatchRevShareNFTMinted(couponBuyer, 9186, 9186);
        revShareModule.batchMint(couponBuyer, 150e6);

        assertEq(revShareModule.couponAmountsByBuyer(couponBuyer), 0);
        assertEq(revShareModule.balanceOf(couponBuyer), 6);
        assert(!revShareModule.isActive(9181));
        assert(!revShareModule.isActive(9182));
        assert(!revShareModule.isActive(9183));
        assert(!revShareModule.isActive(9184));
        assert(!revShareModule.isActive(9185));
        assert(!revShareModule.isActive(9186));
    }

    modifier batchMint() {
        vm.prank(minter);
        revShareModule.batchMint(couponBuyer, 0);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIVATE
    //////////////////////////////////////////////////////////////*/

    function testRevShareModule_activateTokenRevertsIfBuyerIsAddressZero() public {
        vm.prank(minter);
        vm.expectRevert();
        revShareModule.mintOrActivate(
            RevShareModule.Operation.ACTIVATE_NFT,
            address(0),
            address(0),
            0
        );
    }

    function testRevShareModule_activateTokenRevertsIfBuyerDoesNotHaveNfts() public {
        vm.prank(minter);
        vm.expectRevert(RevShareModule.RevShareModule__MintNFTFirst.selector);
        revShareModule.mintOrActivate(
            RevShareModule.Operation.ACTIVATE_NFT,
            address(0),
            couponBuyer,
            0
        );
    }

    function testRevShareModule_activateTokenIncreaseRedeemedAmountIfNotEnoughToActivate()
        public
        increaseCouponAmountByBuyer
        batchMint
    {
        assertEq(revShareModule.couponRedeemedAmountsByBuyer(couponBuyer), 0);

        vm.prank(minter);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnCouponAmountRedeemedByBuyerIncreased(couponBuyer, 100e6);
        revShareModule.mintOrActivate(
            RevShareModule.Operation.ACTIVATE_NFT,
            address(0),
            couponBuyer,
            100e6
        );

        assertEq(revShareModule.couponRedeemedAmountsByBuyer(couponBuyer), 100e6);
    }

    function testRevShareModule_activateToken() public increaseCouponAmountByBuyer batchMint {
        uint256 lastUpdatedTimestamp_initialState = revShareModule.lastUpdatedTimestamp();
        uint256 revenuePerNFTOwned_initialState = revShareModule.revenuePerNFTOwned();
        uint256 userRevenue_initialState = revShareModule.revenues(couponBuyer);
        uint256 userRevenuePerNftPaid_initialState = revShareModule.userRevenuePerNFTPaid(
            couponBuyer
        );
        assertEq(revShareModule.couponRedeemedAmountsByBuyer(couponBuyer), 0);
        assert(!revShareModule.isActive(9181));

        vm.prank(minter);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnRevShareNFTActivated(couponBuyer, 9181);
        revShareModule.mintOrActivate(
            RevShareModule.Operation.ACTIVATE_NFT,
            address(0),
            couponBuyer,
            NFT_PRICE
        );

        assert(revShareModule.lastUpdatedTimestamp() > lastUpdatedTimestamp_initialState);
        assertEq(revenuePerNFTOwned_initialState, 0);
        assertEq(userRevenue_initialState, 0);
        assertEq(revShareModule.revenues(couponBuyer), 0);
        assertApproxEqAbs(revShareModule.revenuePerNFTOwned(), 48e5, 100);
        assertEq(userRevenuePerNftPaid_initialState, 0);
        assertApproxEqAbs(revShareModule.userRevenuePerNFTPaid(couponBuyer), 48e5, 100);
        assert(revShareModule.isActive(9181));
        assertEq(revShareModule.couponRedeemedAmountsByBuyer(couponBuyer), 0);
    }

    function testRevShareModule_activateTokenActivatesOnlyOneAndRewriteCouponsRedeemed()
        public
        increaseCouponAmountByBuyer
        batchMint
    {
        assertEq(revShareModule.couponRedeemedAmountsByBuyer(couponBuyer), 0);
        assert(!revShareModule.isActive(9181));

        vm.prank(minter);
        revShareModule.mintOrActivate(
            RevShareModule.Operation.ACTIVATE_NFT,
            address(0),
            couponBuyer,
            100e6
        );

        assertEq(revShareModule.couponRedeemedAmountsByBuyer(couponBuyer), 100e6);
        assert(!revShareModule.isActive(9181));

        vm.prank(minter);
        revShareModule.mintOrActivate(
            RevShareModule.Operation.ACTIVATE_NFT,
            address(0),
            couponBuyer,
            NFT_PRICE
        );

        assertEq(revShareModule.couponRedeemedAmountsByBuyer(couponBuyer), 100e6);
        assert(revShareModule.isActive(9181));
    }

    function testRevShareModule_activateTokenActivatesInOrder()
        public
        increaseCouponAmountByBuyer
        batchMint
    {
        for (uint256 i = 9181; i <= revShareModule.balanceOf(couponBuyer); i++) {
            assert(!revShareModule.isActive(i));

            vm.prank(minter);
            vm.expectEmit(true, false, false, false, address(revShareModule));
            emit OnRevShareNFTActivated(couponBuyer, i);
            revShareModule.mintOrActivate(
                RevShareModule.Operation.ACTIVATE_NFT,
                address(0),
                couponBuyer,
                NFT_PRICE
            );

            assert(revShareModule.isActive(i));
        }
    }

    modifier activateNft() {
        vm.prank(minter);
        revShareModule.mintOrActivate(
            RevShareModule.Operation.ACTIVATE_NFT,
            address(0),
            couponBuyer,
            NFT_PRICE
        );
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                BALANCES
    //////////////////////////////////////////////////////////////*/

    function testRevShareModule_balanceOf() public increaseCouponAmountByBuyer {
        assertEq(revShareModule.totalSupply(), 9180);
        assertEq(revShareModule.balanceOf(joinerMax), 0);
        assertEq(revShareModule.balanceOf(couponBuyer), 0);
        assertEq(revShareModule.balanceOf(takadao), 9180);

        vm.startPrank(minter);
        revShareModule.mintOrActivate(
            RevShareModule.Operation.SINGLE_MINT,
            joinerMax,
            address(0),
            0
        );

        revShareModule.batchMint(couponBuyer, 0);
        vm.stopPrank();

        assertEq(revShareModule.totalSupply(), 9186);
        assertEq(revShareModule.balanceOf(joinerMax), 1);
        assertEq(revShareModule.balanceOf(couponBuyer), 5);
        assertEq(revShareModule.balanceOf(takadao), 9180);
    }

    /*//////////////////////////////////////////////////////////////
                               TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function testRevShareModule_transferInactiveNftReverts()
        public
        increaseCouponAmountByBuyer
        batchMint
    {
        vm.prank(couponBuyer);
        vm.expectRevert(RevShareModule.RevShareModule__NotActiveToken.selector);
        revShareModule.transfer(joinerMax, 1);
    }

    function testRevShareModule_transferFromInactiveNftReverts()
        public
        increaseCouponAmountByBuyer
        batchMint
    {
        vm.prank(couponBuyer);
        revShareModule.setApprovalForAll(revShareModuleAddress, true);

        vm.prank(revShareModuleAddress);
        vm.expectRevert(RevShareModule.RevShareModule__NotActiveToken.selector);
        revShareModule.transferFrom(couponBuyer, joinerMax, 1);
    }

    function testRevShareModule_transferNft()
        public
        increaseCouponAmountByBuyer
        batchMint
        activateNft
    {
        assertEq(revShareModule.balanceOf(couponBuyer), 5);
        assertEq(revShareModule.balanceOf(joinerMax), 0);

        vm.prank(couponBuyer);
        revShareModule.transfer(joinerMax, 9181);

        assertEq(revShareModule.balanceOf(couponBuyer), 4);
        assertEq(revShareModule.balanceOf(joinerMax), 1);
    }

    function testRevShareModule_transferFromNft()
        public
        increaseCouponAmountByBuyer
        batchMint
        activateNft
    {
        assertEq(revShareModule.balanceOf(couponBuyer), 5);
        assertEq(revShareModule.balanceOf(joinerMax), 0);

        vm.prank(couponBuyer);
        revShareModule.setApprovalForAll(revShareModuleAddress, true);

        vm.prank(revShareModuleAddress);
        revShareModule.transferFrom(couponBuyer, joinerMax, 9181);

        assertEq(revShareModule.balanceOf(couponBuyer), 4);
        assertEq(revShareModule.balanceOf(joinerMax), 1);
    }

    /*//////////////////////////////////////////////////////////////
                             CLAIM REVENUE
    //////////////////////////////////////////////////////////////*/

    function testRevShareModule_claimRevenueRevertsIfNoToken() public {
        vm.prank(joinerMax);
        vm.expectRevert(RevShareModule.RevShareModule__NotNFTOwner.selector);
        revShareModule.claimRevenue();
    }

    function testRevShareModule_claimRevenueRevertsIfNoRevenue() public singleMint {
        vm.prank(joinerMax);
        vm.expectRevert(RevShareModule.RevShareModule__NoRevenueToClaim.selector);
        revShareModule.claimRevenue();

        assertEq(revShareModule.getRevenueEarnedByUser(joinerMax), 0);
    }

    function testRevShareModule_claimRevenueSuccessfully() public singleMint {
        uint256 initialRevenuePerNFT = revShareModule.getRevenuePerNFT();
        uint256 initialUserBalance = usdc.balanceOf(joinerMax);
        uint256 initialContractBalance = usdc.balanceOf(revShareModuleAddress);
        uint256 expectedTransferRevenue = 4;

        vm.warp(2 days);
        vm.roll(block.number + 1);

        vm.prank(joinerMax);

        vm.expectEmit(true, true, false, false, address(usdc));
        emit Transfer(address(revShareModule), joinerMax, expectedTransferRevenue);

        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnRevenueClaimed(joinerMax, expectedTransferRevenue);

        revShareModule.claimRevenue();

        uint256 finalRevenuePerNFT = revShareModule.getRevenuePerNFT();
        uint256 finalUserBalance = usdc.balanceOf(joinerMax);
        uint256 finalContractBalance = usdc.balanceOf(revShareModuleAddress);

        assertApproxEqAbs(initialRevenuePerNFT, 48e5, 100);
        assertApproxEqAbs(finalRevenuePerNFT, 96e5, 100);
        assertEq(finalContractBalance, initialContractBalance - expectedTransferRevenue);
        assertEq(finalUserBalance, initialUserBalance + expectedTransferRevenue);
    }

    modifier claimRevenue() {
        vm.warp(2 days);
        vm.roll(block.number + 1);

        vm.prank(joinerMax);
        revShareModule.claimRevenue();
        _;
    }

    function testRevShareModule_claimRevenueRevertsIfClaimedAndNoTimePassed()
        public
        singleMint
        claimRevenue
    {
        vm.prank(joinerMax);
        vm.expectRevert(RevShareModule.RevShareModule__NoRevenueToClaim.selector);
        revShareModule.claimRevenue();
    }

    function testRevShareModule_claimRevenueAfterSomeTime() public singleMint claimRevenue {
        vm.warp(3 days);
        vm.roll(block.number + 1);

        vm.prank(joinerMax);
        revShareModule.claimRevenue();
    }

    function testRevShareModule_claimRevenueMoreThanOneActive()
        public
        singleMint
        increaseCouponAmountByBuyer
        batchMint
        activateNft
    {
        uint256 expectedTransferRevenue = 4e6;

        vm.warp(2 days);
        vm.roll(block.number + 1);

        vm.startPrank(joinerMax);
        // Can claim
        vm.expectEmit(true, true, false, false, address(usdc));
        emit Transfer(address(revShareModule), joinerMax, expectedTransferRevenue);

        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnRevenueClaimed(joinerMax, expectedTransferRevenue);

        revShareModule.claimRevenue();

        // But can not claim again if no time passed
        vm.expectRevert(RevShareModule.RevShareModule__NoRevenueToClaim.selector);
        revShareModule.claimRevenue();
        vm.stopPrank();

        // But others can claim
        vm.prank(couponBuyer);
        vm.expectEmit(true, true, false, false, address(usdc));
        emit Transfer(address(revShareModule), couponBuyer, expectedTransferRevenue);

        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnRevenueClaimed(couponBuyer, expectedTransferRevenue);
        revShareModule.claimRevenue();

        vm.prank(takadao);
        revShareModule.claimRevenue();
    }
}
