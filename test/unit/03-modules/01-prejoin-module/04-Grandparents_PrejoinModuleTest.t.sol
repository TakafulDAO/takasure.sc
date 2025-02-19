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

contract GrandparentsPrejoinModuleTest is Test {
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
    uint256 public constant LAYER_TWO_REWARD_RATIO = 1; // Layer two reward ratio 1%
    uint256 public constant LAYER_THREE_REWARD_RATIO = 35; // Layer three reward ratio 0.35%
    uint256 public constant LAYER_FOUR_REWARD_RATIO = 175; // Layer four reward ratio 0.175%

    event OnParentRewarded(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward
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

    function testCompleteReferralTreeAssignRewardCorrectly() public createDao {
        // Parents addresses
        address parentTier1 = makeAddr("parentTier1");
        address parentTier2 = makeAddr("parentTier2");
        address parentTier3 = makeAddr("parentTier3");
        address parentTier4 = makeAddr("parentTier4");
        address[4] memory parents = [parentTier1, parentTier2, parentTier3, parentTier4];

        for (uint256 i = 0; i < parents.length; i++) {
            // Give USDC to parents
            deal(address(usdc), parents[i], 10 * CONTRIBUTION_AMOUNT);
            // Approve the contracts
            vm.startPrank(parents[i]);
            usdc.approve(address(prejoinModule), 10 * CONTRIBUTION_AMOUNT);
            vm.stopPrank();
        }

        address childWithoutReferee = makeAddr("childWithoutReferee");
        deal(address(usdc), childWithoutReferee, 10 * CONTRIBUTION_AMOUNT);
        vm.prank(childWithoutReferee);
        usdc.approve(address(prejoinModule), 10 * CONTRIBUTION_AMOUNT);

        // First Parent 1 becomes a member without a referral
        vm.prank(parentTier1);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));
        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier1);

        // Parent 2 prepay referred by parent 1
        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier2);
        prejoinModule.payContribution(parentTier2Contribution, parentTier1);

        // The expected parent 1 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentOneReward = (parentTier2Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        vm.prank(takadao);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier1, 1, parentTier2, expectedParentOneReward);
        prejoinModule.setKYCStatus(parentTier2);

        // Parent 3 prepay referred by parent 2
        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier3);
        prejoinModule.payContribution(parentTier3Contribution, parentTier2);

        // The expected parent 2 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentTwoReward = (parentTier3Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 1% of the parent 2 contribution
        expectedParentOneReward = (parentTier3Contribution * LAYER_TWO_REWARD_RATIO) / 100;

        vm.prank(takadao);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier2, 1, parentTier3, expectedParentTwoReward);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier1, 2, parentTier3, expectedParentOneReward);
        prejoinModule.setKYCStatus(parentTier3);

        // Parent 4 prepay referred by parent 3
        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier4);
        prejoinModule.payContribution(parentTier4Contribution, parentTier3);

        // The expected parent 3 reward ratio will be 4% of the parent 4 contribution
        uint256 expectedParentThreeReward = (parentTier4Contribution * LAYER_ONE_REWARD_RATIO) /
            100;
        // The expected parent 2 reward ratio will be 1% of the parent 4 contribution
        expectedParentTwoReward = (parentTier4Contribution * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 0.35% of the parent 4 contribution
        expectedParentOneReward = (parentTier4Contribution * LAYER_THREE_REWARD_RATIO) / 10000;

        vm.prank(takadao);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier3, 1, parentTier4, expectedParentThreeReward);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier2, 2, parentTier4, expectedParentTwoReward);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier1, 3, parentTier4, expectedParentOneReward);
        prejoinModule.setKYCStatus(parentTier4);

        // Child without referee prepay referred by parent 4
        uint256 childWithoutRefereeContribution = 4 * CONTRIBUTION_AMOUNT;
        vm.prank(childWithoutReferee);
        prejoinModule.payContribution(childWithoutRefereeContribution, parentTier4);

        // The expected parent 4 reward ratio will be 4% of the child without referee contribution
        uint256 expectedParentFourReward = (childWithoutRefereeContribution *
            LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 3 reward ratio will be 1% of the child without referee
        expectedParentThreeReward =
            (childWithoutRefereeContribution * LAYER_TWO_REWARD_RATIO) /
            100;
        // The expected parent 2 reward ratio will be 0.35% of the child without referee contribution
        expectedParentTwoReward =
            (childWithoutRefereeContribution * LAYER_THREE_REWARD_RATIO) /
            10000;
        // The expected parent 1 reward ratio will be 0.175% of the child without referee contribution
        expectedParentOneReward =
            (childWithoutRefereeContribution * LAYER_FOUR_REWARD_RATIO) /
            100000;

        vm.prank(takadao);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier4, 1, childWithoutReferee, expectedParentFourReward);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier3, 2, childWithoutReferee, expectedParentThreeReward);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier2, 3, childWithoutReferee, expectedParentTwoReward);
        vm.expectEmit(true, true, true, true, address(prejoinModule));
        emit OnParentRewarded(parentTier1, 4, childWithoutReferee, expectedParentOneReward);
        prejoinModule.setKYCStatus(childWithoutReferee);
    }

    function testLayersCorrectlyAssigned() public createDao {
        // Parents addresses
        address parentTier1 = makeAddr("parentTier1");
        address parentTier2 = makeAddr("parentTier2");
        address parentTier3 = makeAddr("parentTier3");
        address parentTier4 = makeAddr("parentTier4");
        address[4] memory parents = [parentTier1, parentTier2, parentTier3, parentTier4];
        for (uint256 i = 0; i < parents.length; i++) {
            // Give USDC to parents
            deal(address(usdc), parents[i], 10 * CONTRIBUTION_AMOUNT);
            // Approve the contracts
            vm.startPrank(parents[i]);
            usdc.approve(address(prejoinModule), 10 * CONTRIBUTION_AMOUNT);
            vm.stopPrank();
        }
        address childWithoutReferee = makeAddr("childWithoutReferee");

        deal(address(usdc), childWithoutReferee, 10 * CONTRIBUTION_AMOUNT);
        vm.prank(childWithoutReferee);
        usdc.approve(address(prejoinModule), 10 * CONTRIBUTION_AMOUNT);

        // First Parent 1 becomes a member without a referral
        vm.prank(parentTier1);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));
        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier1);

        // Now parent 1 refer parent 2, this refer parent 3, this refer parent 4 and this refer the child

        // Parent 2 prepay referred by parent 1
        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;

        vm.prank(parentTier2);
        prejoinModule.payContribution(parentTier2Contribution, parentTier1);

        // The expected parent 1 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentOneReward = (parentTier2Contribution * LAYER_ONE_REWARD_RATIO) / 100;

        assertEq(
            prejoinModule.getParentRewardsByChild(parentTier1, parentTier2),
            expectedParentOneReward
        );
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier1, 1), expectedParentOneReward);

        // Parent 3 prepay referred by parent 2
        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier2);

        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        // The expected parent 2 reward ratio will be 4% of the parent 2 contribution
        uint256 expectedParentTwoReward = (parentTier3Contribution * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 1% of the parent 2 contribution
        expectedParentOneReward = (parentTier3Contribution * LAYER_TWO_REWARD_RATIO) / 100;

        vm.prank(parentTier3);
        prejoinModule.payContribution(parentTier3Contribution, parentTier2);

        assertEq(
            prejoinModule.getParentRewardsByChild(parentTier2, parentTier3),
            expectedParentTwoReward
        );
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier2, 1), expectedParentTwoReward);
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier1, 2), expectedParentOneReward);

        // Parent 4 prepay referred by parent 3
        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier3);

        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        // The expected parent 3 reward ratio will be 4% of the parent 4 contribution
        uint256 expectedParentThreeReward = (parentTier4Contribution * LAYER_ONE_REWARD_RATIO) /
            100;
        // The expected parent 2 reward ratio will be 1% of the parent 4 contribution
        expectedParentTwoReward = (parentTier4Contribution * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 1 reward ratio will be 0.35% of the parent 4 contribution
        expectedParentOneReward = (parentTier4Contribution * LAYER_THREE_REWARD_RATIO) / 10000;

        vm.prank(parentTier4);
        prejoinModule.payContribution(parentTier4Contribution, parentTier3);

        assertEq(
            prejoinModule.getParentRewardsByChild(parentTier3, parentTier4),
            expectedParentThreeReward
        );
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier3, 1), expectedParentThreeReward);
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier2, 2), expectedParentTwoReward);
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier1, 3), expectedParentOneReward);

        // Child without referee prepay referred by parent 4
        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier4);

        // The expected parent 4 reward ratio will be 4% of the child without referee contribution
        uint256 expectedParentFourReward = (CONTRIBUTION_AMOUNT * LAYER_ONE_REWARD_RATIO) / 100;
        // The expected parent 3 reward ratio will be 1% of the child without referee
        expectedParentThreeReward = (CONTRIBUTION_AMOUNT * LAYER_TWO_REWARD_RATIO) / 100;
        // The expected parent 2 reward ratio will be 0.35% of the child without referee contribution
        expectedParentTwoReward = (CONTRIBUTION_AMOUNT * LAYER_THREE_REWARD_RATIO) / 10000;
        // The expected parent 1 reward ratio will be 0.175% of the child without referee contribution
        expectedParentOneReward = (CONTRIBUTION_AMOUNT * LAYER_FOUR_REWARD_RATIO) / 100000;

        vm.prank(childWithoutReferee);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, parentTier4);

        assertEq(
            prejoinModule.getParentRewardsByChild(parentTier4, childWithoutReferee),
            expectedParentFourReward
        );
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier4, 1), expectedParentFourReward);
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier3, 2), expectedParentThreeReward);
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier2, 3), expectedParentTwoReward);
        assertEq(prejoinModule.getParentRewardsByLayer(parentTier1, 4), expectedParentOneReward);
    }
}
