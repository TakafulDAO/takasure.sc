// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract RefundsPrejoinModuleTest is Test {
    TestDeployProtocol deployer;
    PrejoinModule prejoinModule;
    TakasureReserve takasureReserve;
    EntryModule entryModule;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address prejoinModuleAddress;
    address takasureReserveAddress;
    address entryModuleAddress;
    address takadao;
    address daoAdmin;
    address KYCProvider;
    address referral = makeAddr("referral");
    address member = makeAddr("member");
    address notMember = makeAddr("notMember");
    address child = makeAddr("child");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (
            ,
            bmConsumerMock,
            takasureReserveAddress,
            prejoinModuleAddress,
            entryModuleAddress,
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
        daoAdmin = config.daoMultisig;
        KYCProvider = config.kycProvider;

        // Assign implementations
        prejoinModule = PrejoinModule(prejoinModuleAddress);
        takasureReserve = TakasureReserve(takasureReserveAddress);
        entryModule = EntryModule(entryModuleAddress);
        usdc = IUSDC(usdcAddress);

        // Config mocks
        vm.prank(daoAdmin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.startPrank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(takasureReserve));
        bmConsumerMock.setNewRequester(prejoinModuleAddress);
        vm.stopPrank();

        // Give and approve USDC
        deal(address(usdc), referral, USDC_INITIAL_AMOUNT);
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        deal(address(usdc), member, USDC_INITIAL_AMOUNT);

        vm.prank(referral);
        usdc.approve(address(prejoinModule), USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(prejoinModule), USDC_INITIAL_AMOUNT);
        vm.prank(member);
        usdc.approve(address(takasureReserve), USDC_INITIAL_AMOUNT);
    }

    modifier createDao() {
        vm.startPrank(daoAdmin);
        prejoinModule.createDAO(true, 1743479999, address(bmConsumerMock));
        vm.stopPrank();
        _;
    }

    modifier referralPrepays() {
        vm.prank(referral);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));
        _;
    }

    modifier KYCReferral() {
        vm.prank(KYCProvider);
        prejoinModule.approveKYC(referral);
        _;
    }

    modifier referredPrepays() {
        vm.prank(child);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, referral);

        _;
    }

    modifier referredIsKYC() {
        vm.prank(KYCProvider);
        prejoinModule.approveKYC(child);
        _;
    }

    function testRefundContractHasEnoughBalance()
        public
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 feeToOperator,
            uint256 discount
        ) = prejoinModule.getPrepaidMember(child);

        assert(contributionBeforeFee > 0);
        assert(contributionAfterFee > 0);
        assert(feeToOperator > 0);
        assert(discount > 0);
        assert(prejoinModule.isMemberKYCed(child));

        vm.startPrank(child);
        // Should not be able to join because the DAO is not launched yet
        vm.expectRevert();
        prejoinModule.joinDAO(child);

        // Should not be able to refund because the launched date is not reached yet
        vm.expectRevert(PrejoinModule.PrejoinModule__tDAONotReadyYet.selector);
        prejoinModule.refundIfDAOIsNotLaunched(child);
        vm.stopPrank();

        (, , , uint256 launchDate, , , , , ) = prejoinModule.getDAOData();

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        vm.startPrank(child);
        // Should not be able to join because the DAO is not launched yet
        vm.expectRevert();
        prejoinModule.joinDAO(child);

        // Should not be able to refund even if the launched date is reached, but has to wait 1 day
        vm.expectRevert(PrejoinModule.PrejoinModule__tDAONotReadyYet.selector);
        prejoinModule.refundIfDAOIsNotLaunched(child);
        vm.stopPrank();

        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        vm.startPrank(child);
        prejoinModule.refundIfDAOIsNotLaunched(child);

        // Should not be able to refund twice
        vm.expectRevert(PrejoinModule.PrejoinModule__HasNotPaid.selector);
        prejoinModule.refundIfDAOIsNotLaunched(child);
        vm.stopPrank();

        (contributionBeforeFee, contributionAfterFee, feeToOperator, discount) = prejoinModule
            .getPrepaidMember(child);

        assertEq(contributionBeforeFee, 0);
        assertEq(contributionAfterFee, 0);
        assertEq(feeToOperator, 0);
        assertEq(discount, 0);
        assert(!prejoinModule.isMemberKYCed(child));

        vm.prank(child);
        vm.expectRevert();
        prejoinModule.joinDAO(child);
    }

    function testRefundContractDontHaveEnoughBalance()
        public
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        // From parent 20 USDC
        // From child 20 USDC
        // Reward 1
        // Balance 39
        assertEq(usdc.balanceOf(address(prejoinModule)), 39e6);

        (
            ,
            ,
            ,
            uint256 launchDate,
            uint256 currentAmount,
            ,
            ,
            uint256 toRepool,
            uint256 referralReserve
        ) = prejoinModule.getDAOData();

        assertEq(currentAmount, 365e5);
        assertEq(toRepool, 1e6);
        assertEq(referralReserve, 15e5);

        vm.warp(launchDate + 1);
        vm.roll(block.number + 1);

        uint256 referralBalanceBeforeRefund = usdc.balanceOf(referral);

        vm.prank(referral);
        prejoinModule.refundIfDAOIsNotLaunched(referral);

        uint256 referralBalanceAfterRefund = usdc.balanceOf(referral);

        // Should refund 25 usdc - discount = 25 - (25 * 10%) = 22.5

        assertEq(referralBalanceAfterRefund, referralBalanceBeforeRefund + 225e5);

        uint256 newExpectedContractBalance = 39e6 - 225e5; // 16.5

        assertEq(usdc.balanceOf(address(prejoinModule)), newExpectedContractBalance);

        (, , , , currentAmount, , , toRepool, referralReserve) = prejoinModule.getDAOData();

        assertEq(currentAmount, 1825e4); // The new currentAmount should be 36.5 - (25 - 25 * 27%) = 36.5 - (25 - 6.75) = 36.5 - 18.25 = 18.25
        assertEq(referralReserve, 0); // The new rr should be 1.5 - (22.5 - 18.25) = 1.5 - 4.25 = 0
        assertEq(toRepool, 0); // The new repool should be 1 - 2.75 = 0

        uint256 amountToRefundToChild = CONTRIBUTION_AMOUNT -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_DISCOUNT_RATIO) / 100); // 25 - (25 * 10%) - (25 * 5%) = 21.25

        vm.prank(child);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrejoinModule.PrejoinModule__NotEnoughFunds.selector,
                amountToRefundToChild,
                newExpectedContractBalance
            )
        );
        prejoinModule.refundIfDAOIsNotLaunched(child);

        address usdcWhale = makeAddr("usdcWhale");
        deal(address(usdc), usdcWhale, 100e6);

        vm.prank(usdcWhale);
        usdc.transfer(address(prejoinModule), amountToRefundToChild - newExpectedContractBalance);

        assertEq(usdc.balanceOf(address(prejoinModule)), amountToRefundToChild);

        uint256 childBalanceBeforeRefund = usdc.balanceOf(child);

        vm.prank(child);
        prejoinModule.refundIfDAOIsNotLaunched(child);

        assertEq(usdc.balanceOf(address(child)), childBalanceBeforeRefund + amountToRefundToChild);
        assertEq(usdc.balanceOf(address(prejoinModule)), 0);

        (, , , , currentAmount, , , toRepool, referralReserve) = prejoinModule.getDAOData();

        assertEq(currentAmount, 0);
        assertEq(toRepool, 0);
        assertEq(referralReserve, 0);
    }

    function testCanNotRefundIfDaoIsLaunched()
        public
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        (, , , uint256 launchDate, , , , , ) = prejoinModule.getDAOData();

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        vm.prank(daoAdmin);
        prejoinModule.launchDAO(address(takasureReserve), entryModuleAddress, true);

        vm.prank(child);
        vm.expectRevert(PrejoinModule.PrejoinModule__tDAONotReadyYet.selector);
        prejoinModule.refundIfDAOIsNotLaunched(child);
    }

    function testRefundByAdminEvenIfDaoIsNotYetLaunched()
        public
        createDao
        referralPrepays
        KYCReferral
        referredPrepays
        referredIsKYC
    {
        vm.prank(daoAdmin);
        vm.expectRevert(PrejoinModule.PrejoinModule__tDAONotReadyYet.selector);
        prejoinModule.refundIfDAOIsNotLaunched(child);

        vm.prank(daoAdmin);
        prejoinModule.refundByAdmin(child);
    }
}
