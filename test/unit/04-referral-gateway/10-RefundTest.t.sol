// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract ReferralGatewayRefundTest is Test, SimulateDonResponse {
    TestDeployTakasureReserve deployer;
    ReferralGateway referralGateway;
    TakasureReserve takasureReserve;
    EntryModule entryModule;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takasureReserveAddress;
    address entryModuleAddress;
    address takadao;
    address daoAdmin;
    address KYCProvider;
    address pauseGuardian;
    address referral = makeAddr("referral");
    address member = makeAddr("member");
    address child = makeAddr("child");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant LAYER_ONE_REWARD_RATIO = 4; // Layer one reward ratio 4%
    uint256 public constant LAYER_TWO_REWARD_RATIO = 1; // Layer two reward ratio 1%
    uint256 public constant LAYER_THREE_REWARD_RATIO = 35; // Layer three reward ratio 0.35%
    uint256 public constant LAYER_FOUR_REWARD_RATIO = 175; // Layer four reward ratio 0.175%
    uint8 public constant SERVICE_FEE_RATIO = 27;
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution
    uint256 public constant REFERRAL_RESERVE = 5; // 5% of contribution TO Referral Reserve
    uint256 public constant REPOOL_FEE_RATIO = 2; // 2% of contribution deducted from fee

    struct PrepaidMember {
        string tDAOName;
        address member;
        uint256 contributionBeforeFee;
        uint256 contributionAfterFee;
        uint256 finalFee; // Fee after all the discounts and rewards
        uint256 discount;
    }

    event OnPrepayment(
        address indexed parent,
        address indexed child,
        uint256 indexed contribution,
        uint256 fee,
        uint256 discount
    );
    event OnMemberJoined(uint256 indexed memberId, address indexed member);
    event OnParentRewardTransferStatus(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward,
        bool status
    );

    function setUp() public {
        // Deployer
        deployer = new TestDeployTakasureReserve();
        // Deploy contracts
        (
            ,
            bmConsumerMock,
            takasureReserveAddress,
            entryModuleAddress,
            ,
            ,
            ,
            referralGatewayAddress,
            usdcAddress,
            ,
            helperConfig
        ) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        daoAdmin = config.daoMultisig;
        KYCProvider = config.kycProvider;
        pauseGuardian = config.pauseGuardian;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
        takasureReserve = TakasureReserve(takasureReserveAddress);
        entryModule = EntryModule(entryModuleAddress);
        usdc = IUSDC(usdcAddress);

        // Config mocks
        vm.prank(daoAdmin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(takasureReserve));
        bmConsumerMock.setNewRequester(referralGatewayAddress);

        // Give and approve USDC
        deal(address(usdc), referral, USDC_INITIAL_AMOUNT);
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        deal(address(usdc), member, USDC_INITIAL_AMOUNT);

        vm.prank(referral);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(member);
        usdc.approve(address(takasureReserve), USDC_INITIAL_AMOUNT);

        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        referralGateway.setDaoName(tDaoName);
        referralGateway.createDAO(true, true, 1743479999, 1e12, address(bmConsumerMock));
        vm.stopPrank();

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            referral,
            0,
            false
        );
    }

    modifier KYCReferral() {
        vm.prank(KYCProvider);
        referralGateway.approveKYC(referral);
        _;
    }

    modifier referredPrepays() {
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, referral, child, 0, false);

        _;
    }

    modifier referredIsKYC() {
        vm.prank(KYCProvider);
        referralGateway.approveKYC(child);
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                    REFUNDS
        //////////////////////////////////////////////////////////////*/

    function testRefundContractHasEnoughBalance() public KYCReferral referredPrepays referredIsKYC {
        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 feeToOperator,
            uint256 discount
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

        (, , , , uint256 launchDate, , , , , , ) = referralGateway.getDAOData();

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

        (contributionBeforeFee, contributionAfterFee, feeToOperator, discount) = referralGateway
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

    function testRefundContractDontHaveEnoughBalance()
        public
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        // From parent 20 USDC
        // From child 20 USDC
        // Reward 1
        // Balance 39
        assertEq(usdc.balanceOf(address(referralGateway)), 39e6);

        (
            ,
            ,
            ,
            ,
            uint256 launchDate,
            ,
            uint256 currentAmount,
            ,
            ,
            uint256 toRepool,
            uint256 referralReserve
        ) = referralGateway.getDAOData();

        assertEq(currentAmount, 365e5);
        assertEq(toRepool, 1e6);
        assertEq(referralReserve, 15e5);

        vm.warp(launchDate + 1);
        vm.roll(block.number + 1);

        uint256 referralBalanceBeforeRefund = usdc.balanceOf(referral);

        vm.prank(referral);
        referralGateway.refundIfDAOIsNotLaunched(referral);

        uint256 referralBalanceAfterRefund = usdc.balanceOf(referral);

        // Should refund 25 usdc - discount = 25 - (25 * 10%) = 22.5

        assertEq(referralBalanceAfterRefund, referralBalanceBeforeRefund + 225e5);

        uint256 newExpectedContractBalance = 39e6 - 225e5; // 16.5

        assertEq(usdc.balanceOf(address(referralGateway)), newExpectedContractBalance);

        (, , , , , , currentAmount, , , toRepool, referralReserve) = referralGateway.getDAOData();

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

        (, , , , , , currentAmount, , , toRepool, referralReserve) = referralGateway.getDAOData();

        assertEq(currentAmount, 0);
        assertEq(toRepool, 0);
        assertEq(referralReserve, 0);
    }

    function testCanNotRefundIfDaoIsLaunched() public KYCReferral referredPrepays referredIsKYC {
        (, , , , uint256 launchDate, , , , , , ) = referralGateway.getDAOData();

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        vm.prank(daoAdmin);
        referralGateway.launchDAO(address(takasureReserve), true);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);
    }

    function testRefundByAdminEvenIfDaoIsNotYetLaunched()
        public
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);

        vm.prank(daoAdmin);
        referralGateway.refundByAdmin(child);
    }
}
