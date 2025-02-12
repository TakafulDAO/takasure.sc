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
import {AddressCheck} from "contracts/helpers/libraries/checks/AddressCheck.sol";

contract PrepaysPrejoinModuleTest is Test {
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
    string tDaoName = "TheLifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant LAYER_ONE_REWARD_RATIO = 4; // Layer one reward ratio 4%
    uint8 public constant SERVICE_FEE_RATIO = 27;
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution
    uint256 public constant REFERRAL_RESERVE = 5; // 5% of contribution TO Referral Reserve
    uint256 public constant REPOOL_FEE_RATIO = 2; // 2% of contribution deducted from fee

    event OnPrepayment(
        address indexed parent,
        address indexed child,
        uint256 indexed contribution,
        uint256 fee,
        uint256 discount
    );

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
        vm.startPrank(daoAdmin);
        takasureReserve.setNewContributionToken(address(usdc));
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));
        vm.stopPrank();

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
        prejoinModule.createDAO(tDaoName, true, true, 1743479999, 1e12, address(bmConsumerMock));
        prejoinModule.setDAOName(tDaoName);
        vm.stopPrank();
        _;
    }

    //======== preJoinEnabled = true, referralDiscount = true, no referral ========//
    function testprepaymentCase1() public createDao {
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            (((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100)) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100;

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));

        (, , , uint256 discount) = prejoinModule.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 2_500_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = true, invalid referral ========//
    function testprepaymentCase2() public createDao {
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        vm.prank(child);
        vm.expectRevert(PrejoinModule.PrejoinModule__ParentMustKYCFirst.selector);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, referral);

        (, , , , , , , uint256 totalCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(totalCollectedFees, 0);
    }

    //======== preJoinEnabled = true, referralDiscount = false, no referral ========//
    function testprepaymentCase3() public createDao {
        vm.prank(daoAdmin);
        prejoinModule.switchReferralDiscount();

        (, , , , , , , uint256 alreadyCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = (CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100;

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnPrepayment(address(0), child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));

        (, , , uint256 discount) = prejoinModule.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(totalCollectedFees, collectedFees);
        assertEq(collectedFees, 3_750_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = false, invalid referral ========//
    function testprepaymentCase4() public createDao {
        vm.prank(daoAdmin);
        prejoinModule.switchReferralDiscount();

        (, , , , , , , uint256 alreadyCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(alreadyCollectedFees, 0);

        vm.prank(child);
        vm.expectRevert(PrejoinModule.PrejoinModule__ParentMustKYCFirst.selector);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, referral);

        (, , , , , , , uint256 totalCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(totalCollectedFees, 0);
    }

    modifier referralPrepays() {
        vm.prank(referral);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));
        _;
    }

    function testKYCAnAddress() public createDao referralPrepays {
        vm.prank(KYCProvider);
        vm.expectRevert(AddressCheck.TakasureProtocol__ZeroAddress.selector);
        prejoinModule.setKYCStatus(address(0));

        assert(!prejoinModule.isMemberKYCed(referral));
        vm.prank(KYCProvider);
        prejoinModule.setKYCStatus(referral);
        assert(prejoinModule.isMemberKYCed(referral));
    }

    function testMustRevertIfKYCTwiceSameAddress() public createDao referralPrepays {
        vm.startPrank(KYCProvider);
        prejoinModule.setKYCStatus(referral);
        vm.expectRevert(PrejoinModule.PrejoinModule__MemberAlreadyKYCed.selector);
        prejoinModule.setKYCStatus(referral);
        vm.stopPrank();
    }

    modifier KYCReferral() {
        vm.prank(KYCProvider);
        prejoinModule.setKYCStatus(referral);
        _;
    }

    //======== preJoinEnabled = true, referralDiscount = true, valid referral ========//
    function testprepaymentCase5() public createDao referralPrepays KYCReferral {
        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_RESERVE) / 100) -
            ((CONTRIBUTION_AMOUNT * REFERRAL_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100) + ((CONTRIBUTION_AMOUNT * REFERRAL_DISCOUNT_RATIO) / 100);

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnPrepayment(referral, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, referral);

        (, , , uint256 discount) = prejoinModule.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(collectedFees, 1_250_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(prejoinModule.getParentRewardsByChild(referral, child), expectedParentReward);
        assertEq(expectedParentReward, 1_000_000);
        assertEq(discount, expectedDiscount);
    }

    //======== preJoinEnabled = true, referralDiscount = false, valid referral ========//
    function testprepaymentCase6() public createDao referralPrepays KYCReferral {
        vm.prank(daoAdmin);
        prejoinModule.switchReferralDiscount();

        // Already collected fees with the modifiers logic
        (, , , , , , , uint256 alreadyCollectedFees, , , ) = prejoinModule.getDAOData();
        assertEq(alreadyCollectedFees, 2_500_000);

        uint256 expectedParentReward = 0;

        uint256 fees = (CONTRIBUTION_AMOUNT * SERVICE_FEE_RATIO) / 100;
        uint256 collectedFees = fees -
            ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100) -
            ((CONTRIBUTION_AMOUNT * REPOOL_FEE_RATIO) / 100);

        uint256 expectedDiscount = ((CONTRIBUTION_AMOUNT * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) /
            100);

        vm.prank(child);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnPrepayment(referral, child, CONTRIBUTION_AMOUNT, collectedFees, expectedDiscount);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, referral);

        (, , , uint256 discount) = prejoinModule.getPrepaidMember(child);

        (, , , , , , , uint256 totalCollectedFees, , , ) = prejoinModule.getDAOData();

        assertEq(collectedFees, 3_750_000);
        assertEq(totalCollectedFees, collectedFees + alreadyCollectedFees);
        assertEq(prejoinModule.getParentRewardsByChild(referral, child), expectedParentReward);
        assertEq(discount, expectedDiscount);
    }
}
