// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract RevShareModuleTest is Test, SimulateDonResponse {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    EntryModule entryModule;
    RevShareModule revShareModule;
    IUSDC usdc;
    address admin;
    address takadao;
    address kycService;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address entryModuleAddress;
    address revShareModuleAddress;
    address couponPool = makeAddr("couponPool");
    address couponRedeemer = makeAddr("couponRedeemer");
    address couponBuyer = makeAddr("couponBuyer");
    address couponJoiner = makeAddr("couponJoiner");
    address couponJoinerMax = makeAddr("couponJoinerMax");
    address joiner = makeAddr("joiner");
    address joinerMax = makeAddr("joinerMax");
    address joinerMaxNoKyc = makeAddr("joinerMaxNoKyc");
    uint256 public constant MAX_CONTRIBUTION = 250e6; // 250 USDC
    uint256 public constant NO_MAX_CONTRIBUTION = 25e6; // 25 USDC
    uint256 public constant NO_MAX_COUPON = 200e6; // 200 USDC
    uint256 public constant YEAR = 365 days;

    event OnRevShareNFTMinted(address indexed member, uint256 tokenId);
    event OnRevShareNFTActivated(address indexed couponBuyer, uint256 tokenId);

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            ,
            bmConsumerMock,
            takasureReserveProxy,
            ,
            entryModuleAddress,
            ,
            ,
            revShareModuleAddress,
            ,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        entryModule = EntryModule(entryModuleAddress);
        revShareModule = RevShareModule(revShareModuleAddress);

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(entryModuleAddress));

        vm.startPrank(takadao);
        entryModule.updateBmAddress();
        entryModule.setCouponPoolAddress(couponPool);
        entryModule.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        revShareModule.grantRole(keccak256("COUPON_REDEEMER"), address(couponRedeemer));
        vm.stopPrank();

        deal(address(usdc), couponPool, 1 ether);

        vm.prank(couponPool);
        usdc.approve(address(entryModule), 1 ether);

        // No coupons
        // No maximum contribution
        _join(joiner, NO_MAX_CONTRIBUTION);
        // Maximum contribution, no KYC
        _join(joinerMaxNoKyc, MAX_CONTRIBUTION);
        // Maximum contribution
        _join(joinerMax, MAX_CONTRIBUTION);

        // Coupons
        // No maximum contribution
        // _joinWithCoupon(couponJoiner, NO_MAX_CONTRIBUTION, NO_MAX_COUPON);
        // Maximum contribution
        // _joinWithCoupon(couponJoinerMax, MAX_CONTRIBUTION, MAX_CONTRIBUTION);

        // KYC
        _kyc(joiner);
        _kyc(joinerMax);

        vm.prank(couponRedeemer);
        revShareModule.increaseCouponAmountByBuyer(couponBuyer, 5 * MAX_CONTRIBUTION);

        vm.prank(address(entryModule));
        revShareModule.increaseCouponRedeemedAmountByBuyer(
            couponBuyer,
            couponJoiner,
            NO_MAX_COUPON
        );

        vm.prank(address(entryModule));
        revShareModule.increaseCouponRedeemedAmountByBuyer(
            couponBuyer,
            couponJoinerMax,
            MAX_CONTRIBUTION
        );

        vm.warp(1 days);
        vm.roll(block.number + 1);
    }

    function _join(address _joiner, uint256 _contribution) internal {
        deal(address(usdc), _joiner, _contribution);

        vm.startPrank(_joiner);
        usdc.approve(address(entryModule), _contribution);
        entryModule.joinPool(_joiner, address(0), _contribution, (5 * YEAR));
        vm.stopPrank();

        _successResponse(address(bmConsumerMock));
    }

    function _joinWithCoupon(address _joiner, uint256 _contribution, uint256 _coupon) internal {
        entryModule.joinPoolOnBehalfOf(
            _joiner,
            address(0),
            _contribution,
            (5 * YEAR),
            _coupon,
            couponBuyer
        );
    }

    function _kyc(address _joiner) internal {
        vm.prank(kycService);
        entryModule.setKYCStatus(_joiner);
    }

    function testRevShareModule_constants() public view {
        assertEq(revShareModule.MAX_CONTRIBUTION(), MAX_CONTRIBUTION);
        assertEq(revShareModule.TOTAL_SUPPLY(), 18_000);
    }

    function testRevShareModule_MintMustRevertIfNoKycEvenIfMaxContrbution() public {
        vm.prank(joinerMaxNoKyc);
        vm.expectRevert(RevShareModule.RevShareModule__NotAllowedToMint.selector);
        revShareModule.mint();
    }

    function testRevShareModule_MintMustRevertIfNoMaxContribution() public {
        vm.prank(joiner);
        vm.expectRevert(RevShareModule.RevShareModule__NotAllowedToMint.selector);
        revShareModule.mint();
    }

    function testRevShareModule_mint() public {
        uint256 lastUpdatedTimestamp_initialState = revShareModule.lastUpdatedTimestamp();
        uint256 latestTokenId_initialState = revShareModule.latestTokenId();
        bool isNftActive_initialState = revShareModule.isNFTActive(latestTokenId_initialState + 1);
        bool joinerClaimed_initialState = revShareModule.claimedNFTs(joinerMax);
        uint256 joinerBalance_initialState = revShareModule.balanceOf(joinerMax);
        uint256 revenuePerNFTOwned_initialState = revShareModule.revenuePerNFTOwned();
        uint256 userRevenue_initialState = revShareModule.revenues(joinerMax);
        uint256 userRevenuePerNftPaid_initialState = revShareModule.userRevenuePerNFTPaid(
            joinerMax
        );

        vm.prank(joinerMax);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnRevShareNFTMinted(joinerMax, latestTokenId_initialState + 1);
        revShareModule.mint();

        assert(revShareModule.lastUpdatedTimestamp() > lastUpdatedTimestamp_initialState);
        assertEq(revShareModule.latestTokenId(), latestTokenId_initialState + 1);
        assert(!isNftActive_initialState);
        assert(revShareModule.isNFTActive(revShareModule.latestTokenId()));
        assert(!joinerClaimed_initialState);
        assert(revShareModule.claimedNFTs(joinerMax));
        assertEq(joinerBalance_initialState, 0);
        assertEq(revShareModule.balanceOf(joinerMax), 1);
        assertEq(userRevenue_initialState, 0);
        assertEq(revShareModule.revenues(joinerMax), 0);
        assertEq(revenuePerNFTOwned_initialState, 0);
        assertApproxEqAbs(revShareModule.revenuePerNFTOwned(), 48e5, 100);
        assertEq(userRevenuePerNftPaid_initialState, 0);
        assertApproxEqAbs(revShareModule.userRevenuePerNFTPaid(joinerMax), 48e5, 100);
    }

    function testRevShareModule_batchMint() public {
        uint256 latestTokenId_initialState = revShareModule.latestTokenId();
        bool isNft1Active_initialState = revShareModule.isNFTActive(1);
        bool isNft2Active_initialState = revShareModule.isNFTActive(2);
        bool isNft3Active_initialState = revShareModule.isNFTActive(3);
        bool isNft4Active_initialState = revShareModule.isNFTActive(4);
        bool isNft5Active_initialState = revShareModule.isNFTActive(5);
        uint256 couponBuyerBalance_initialState = revShareModule.balanceOf(couponBuyer);

        vm.prank(couponBuyer);

        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnRevShareNFTMinted(couponBuyer, 1);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnRevShareNFTMinted(couponBuyer, 2);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnRevShareNFTMinted(couponBuyer, 3);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnRevShareNFTMinted(couponBuyer, 4);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnRevShareNFTMinted(couponBuyer, 5);

        revShareModule.batchMint();

        assertEq(revShareModule.latestTokenId(), latestTokenId_initialState + 5);
        assert(!isNft1Active_initialState);
        assert(!isNft2Active_initialState);
        assert(!isNft3Active_initialState);
        assert(!isNft4Active_initialState);
        assert(!isNft5Active_initialState);
        assert(!revShareModule.isNFTActive(1));
        assert(!revShareModule.isNFTActive(2));
        assert(!revShareModule.isNFTActive(3));
        assert(!revShareModule.isNFTActive(4));
        assert(!revShareModule.isNFTActive(5));
        assertEq(couponBuyerBalance_initialState, 0);
        assertEq(revShareModule.balanceOf(couponBuyer), 5);
    }

    modifier mint() {
        vm.prank(joinerMax);
        revShareModule.mint();
        _;
    }

    modifier batchMint() {
        vm.prank(couponBuyer);
        revShareModule.batchMint();
        _;
    }

    function testRevShareModule_activateToken() public batchMint {
        uint256 lastUpdatedTimestamp_initialState = revShareModule.lastUpdatedTimestamp();
        bool isNftActive_initialState = revShareModule.isNFTActive(1);
        uint256 userRevenue_initialState = revShareModule.revenues(couponBuyer);
        uint256 revenuePerNFTOwned_initialState = revShareModule.revenuePerNFTOwned();
        uint256 userRevenuePerNftPaid_initialState = revShareModule.userRevenuePerNFTPaid(
            couponBuyer
        );

        vm.prank(couponBuyer);
        vm.expectEmit(true, false, false, false, address(revShareModule));
        emit OnRevShareNFTActivated(couponBuyer, 1);
        revShareModule.activateNFT();

        assert(revShareModule.lastUpdatedTimestamp() > lastUpdatedTimestamp_initialState);
        assert(!isNftActive_initialState);
        assert(revShareModule.isNFTActive(1));
        assertEq(userRevenue_initialState, 0);
        assertEq(revShareModule.revenues(couponBuyer), 0);
        assertEq(revenuePerNFTOwned_initialState, 0);
        assertApproxEqAbs(revShareModule.revenuePerNFTOwned(), 48e5, 100);
        assertEq(userRevenuePerNftPaid_initialState, 0);
        assertApproxEqAbs(revShareModule.userRevenuePerNFTPaid(couponBuyer), 48e5, 100);
    }

    modifier activateNft() {
        vm.prank(couponBuyer);
        revShareModule.activateNFT();
        _;
    }

    function testRevShareModule_transferInactiveNftReverts() public batchMint activateNft {
        vm.prank(couponBuyer);
        vm.expectRevert(RevShareModule.RevShareModule__NotActiveToken.selector);
        revShareModule.transfer(joinerMax, 2);
    }
}
