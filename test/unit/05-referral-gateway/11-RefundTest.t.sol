// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {IReferralGateway, DaoDataReader} from "test/helpers/lowLevelCall/DaoDataReader.sol";

contract ReferralGatewayRefundTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takasureReserveAddress;
    address takadao;
    address KYCProvider;
    address parent = makeAddr("parent");
    address child = makeAddr("child");
    address couponRedeemer = makeAddr("couponRedeemer");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (
            takasureReserveAddress,
            referralGatewayAddress,
            ,
            ,
            ,
            ,
            ,
            ,
            usdcAddress,
            ,
            helperConfig
        ) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        KYCProvider = config.kycProvider;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
        takasureReserve = TakasureReserve(takasureReserveAddress);
        usdc = IUSDC(usdcAddress);

        // Give and approve USDC
        deal(address(usdc), parent, USDC_INITIAL_AMOUNT);
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);

        vm.prank(parent);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        referralGateway.createDAO(true, true, 1743479999, 1e12);
        vm.stopPrank();

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            parent,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(parent);

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, parent, child, 0, false);

        vm.prank(KYCProvider);
        referralGateway.approveKYC(child);
    }

    function testRefundContractHasEnoughBalance() public {
        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 feeToOperator,
            uint256 discount,

        ) = referralGateway.getPrepaidMember(child);

        assert(contributionBeforeFee > 0);
        assert(contributionAfterFee > 0);
        assert(feeToOperator > 0);
        assert(discount > 0);
        assert(referralGateway.isMemberKYCed(child));

        vm.startPrank(child);
        // Should not be able to join because the DAO is not launched yet
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.joinDAO(child);

        // Should not be able to refund because the launched date is not reached yet
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);
        vm.stopPrank();

        uint256 launchDate = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 5);

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        vm.startPrank(child);
        // Should not be able to join because the DAO is not launched yet
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.joinDAO(child);

        // Should not be able to refund even if the launched date is reached, but has to wait 1 day
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.startPrank(child);
        referralGateway.refundIfDAOIsNotLaunched(child);

        // Should not be able to refund twice
        vm.expectRevert(ReferralGateway.ReferralGateway__HasNotPaid.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);
        vm.stopPrank();

        (contributionBeforeFee, contributionAfterFee, feeToOperator, discount, ) = referralGateway
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 0);
        assertEq(contributionAfterFee, 0);
        assertEq(feeToOperator, 0);
        assertEq(discount, 0);
        assert(!referralGateway.isMemberKYCed(child));

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotKYCed.selector);
        referralGateway.joinDAO(child);
    }

    function testRefundContractDontHaveEnoughBalance() public {
        // From parent 20 USDC
        // From child 20 USDC
        // Reward 1
        // Balance 39
        assertEq(usdc.balanceOf(address(referralGateway)), 39e6);

        uint256 launchDate = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 5);
        uint256 currentAmount = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            7
        );
        uint256 toRepool = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 10);
        uint256 referralReserve = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            11
        );

        assertEq(currentAmount, 365e5);
        assertEq(toRepool, 1e6);
        assertEq(referralReserve, 15e5);

        vm.warp(launchDate + 1);
        vm.roll(block.number + 1);

        uint256 parentBalanceBeforeRefund = usdc.balanceOf(parent);

        vm.prank(parent);
        referralGateway.refundIfDAOIsNotLaunched(parent);

        uint256 parentBalanceAfterRefund = usdc.balanceOf(parent);

        // Should refund 25 usdc - discount = 25 - (25 * 10%) = 22.5

        assertEq(parentBalanceAfterRefund, parentBalanceBeforeRefund + 225e5);

        uint256 newExpectedContractBalance = 39e6 - 225e5; // 16.5

        assertEq(usdc.balanceOf(address(referralGateway)), newExpectedContractBalance);

        currentAmount = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 7);
        toRepool = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 10);
        referralReserve = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 11);

        assertEq(currentAmount, 1825e4); // The new currentAmount should be 36.5 - (25 - 25 * 27%) = 36.5 - (25 - 6.75) = 36.5 - 18.25 = 18.25
        assertEq(referralReserve, 0); // The new rr should be 1.5 - (22.5 - 18.25) = 1.5 - 4.25 = 0
        assertEq(toRepool, 0); // The new repool should be 1 - 2.75 = 0

        uint256 amountToRefundToChild = CONTRIBUTION_AMOUNT -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_DISCOUNT_RATIO) / 100); // 25 - (25 * 10%) - (25 * 5%) = 21.25

        vm.prank(child);
        vm.expectRevert(
            abi.encodeWithSelector(
                ReferralGateway.ReferralGateway__NotEnoughFunds.selector,
                amountToRefundToChild,
                newExpectedContractBalance
            )
        );
        referralGateway.refundIfDAOIsNotLaunched(child);

        address usdcWhale = makeAddr("usdcWhale");
        deal(address(usdc), usdcWhale, 100e6);

        vm.prank(usdcWhale);
        usdc.transfer(address(referralGateway), amountToRefundToChild - newExpectedContractBalance);

        assertEq(usdc.balanceOf(address(referralGateway)), amountToRefundToChild);

        uint256 childBalanceBeforeRefund = usdc.balanceOf(child);

        vm.prank(child);
        referralGateway.refundIfDAOIsNotLaunched(child);

        assertEq(usdc.balanceOf(address(child)), childBalanceBeforeRefund + amountToRefundToChild);
        assertEq(usdc.balanceOf(address(referralGateway)), 0);

        currentAmount = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 7);
        toRepool = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 10);
        referralReserve = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 11);

        assertEq(currentAmount, 0);
        assertEq(toRepool, 0);
        assertEq(referralReserve, 0);
    }

    function testCanNotRefundIfDaoIsLaunched() public {
        uint256 launchDate = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 5);

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        address subscriptionModule = makeAddr("subscriptionModule");

        vm.prank(takadao);
        referralGateway.launchDAO(address(takasureReserve), subscriptionModule, true);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);
    }

    function testRefundByAdminEvenIfDaoIsNotYetLaunched() public {
        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);

        vm.prank(takadao);
        referralGateway.refundByAdmin(child);
    }
}
