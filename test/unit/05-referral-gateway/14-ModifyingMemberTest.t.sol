// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayWithCouponWithParentPaymentTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takadao;
    address kycProvider;
    address child = makeAddr("child");
    address parent = makeAddr("parent");
    address couponPool = makeAddr("couponPool");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDAO";
    uint256 public constant USDC_INITIAL_AMOUNT = 1000e6; // 1000 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 225e6; // 225 USDC
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from fee

    event OnCouponRedeemed(
        address indexed member,
        string indexed tDAOName,
        uint256 indexed couponAmount
    );

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (, referralGatewayAddress, , , , , , usdcAddress, , helperConfig) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        kycProvider = config.kycProvider;

        // Assign implementations
        referralGateway = ReferralGateway(address(referralGatewayAddress));
        usdc = IUSDC(usdcAddress);

        // Give and approve USDC
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        deal(address(usdc), parent, USDC_INITIAL_AMOUNT);

        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        vm.prank(parent);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        deal(address(usdc), couponPool, 1000e6);

        vm.prank(couponPool);
        usdc.approve(address(referralGateway), 1000e6);

        vm.prank(config.daoMultisig);
        referralGateway.createDAO(true, true, 1743479999, 1e12);

        vm.startPrank(takadao);
        referralGateway.setCouponPoolAddress(couponPool);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        vm.stopPrank();

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            parent,
            0,
            false
        );

        vm.prank(kycProvider);
        referralGateway.approveKYC(parent);

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(25e6, parent, child, 0, true);
    }

    //======== preJoinEnabled = true, referralDiscount = true, rewardsEnabled = true, with parent, coupon less than contribution ========//
    function testModifyExistingMember() public {
        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 fee,
            uint256 discount,
            bool isDonated
        ) = referralGateway.getPrepaidMember(child);

        assertEq(contributionBeforeFee, 25e6);
        assertEq(contributionAfterFee, 1825e4);
        assertEq(fee, 125e4);
        assertEq(discount, 375e4);
        assert(isDonated);

        uint256 couponAmount = 100e6; // 100 USDC

        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(referralGateway));
        emit OnCouponRedeemed(child, tDaoName, couponAmount);
        (uint256 feeToOp, ) = referralGateway.modifyPrepaidMember(
            CONTRIBUTION_AMOUNT,
            child,
            couponAmount
        );

        uint256 prejoinDiscount = ((CONTRIBUTION_AMOUNT - couponAmount) *
            CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100;
        uint256 referralDiscount = ((CONTRIBUTION_AMOUNT - couponAmount) *
            REFERRAL_DISCOUNT_RATIO) / 100;
        uint256 expectedDiscount = prejoinDiscount + referralDiscount;
        // (contribution - coupon) - (((contribution - coupon) * prejoinDiscount) + ((contribution - coupon) * referralDiscount))
        // (225 - 100) - (((225 - 100) * 10%) + ((225 - 100) * 5%)) = 125 - (12.5 + 6.25) = 125 - 18.75 = 106.25
        uint256 expectedTransfer = (CONTRIBUTION_AMOUNT - couponAmount) - expectedDiscount;

        assertEq(expectedTransfer, 10625e4);
        // The fee to operator should be fee-disount-referralReserve-repoolFee
        assertEq(feeToOp, 2625e4);
        assertEq(expectedDiscount, 1875e4);

        (contributionBeforeFee, contributionAfterFee, fee, discount, isDonated) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 250e6);
        assertEq(contributionAfterFee, 1825e5);
        assertEq(fee, 275e5);
        assertEq(discount, 225e5);
        assert(!isDonated);
    }
}
