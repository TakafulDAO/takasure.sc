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

contract RepoolPrejoinModuleTest is Test {
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

    function testTransferToRepool() public createDao {
        address parentTier1 = makeAddr("parentTier1");
        address parentTier2 = makeAddr("parentTier2");
        address parentTier3 = makeAddr("parentTier3");
        address parentTier4 = makeAddr("parentTier4");
        address[4] memory parents = [parentTier1, parentTier2, parentTier3, parentTier4];

        for (uint256 i = 0; i < parents.length; i++) {
            deal(address(usdc), parents[i], 10 * CONTRIBUTION_AMOUNT);
            vm.startPrank(parents[i]);
            usdc.approve(address(prejoinModule), 10 * CONTRIBUTION_AMOUNT);
            vm.stopPrank();
        }

        address childWithoutReferee = makeAddr("childWithoutReferee");
        deal(address(usdc), childWithoutReferee, 10 * CONTRIBUTION_AMOUNT);
        vm.prank(childWithoutReferee);
        usdc.approve(address(prejoinModule), 10 * CONTRIBUTION_AMOUNT);

        vm.prank(parentTier1);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));
        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier1);

        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier2);
        prejoinModule.payContribution(parentTier2Contribution, parentTier1);

        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier2);

        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier3);
        prejoinModule.payContribution(parentTier3Contribution, parentTier2);

        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier3);

        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        vm.prank(parentTier4);
        prejoinModule.payContribution(parentTier4Contribution, parentTier3);

        vm.prank(takadao);
        prejoinModule.setKYCStatus(parentTier4);

        uint256 childWithoutRefereeContribution = 4 * CONTRIBUTION_AMOUNT;
        vm.prank(childWithoutReferee);
        prejoinModule.payContribution(childWithoutRefereeContribution, parentTier4);

        vm.prank(takadao);
        prejoinModule.setKYCStatus(childWithoutReferee);

        vm.prank(daoAdmin);
        prejoinModule.launchDAO(address(takasureReserve), entryModuleAddress, true);

        address rePoolAddress = makeAddr("rePoolAddress");

        vm.prank(daoAdmin);
        prejoinModule.enableRepool(rePoolAddress);

        (, , , , , , , , , uint256 toRepool, ) = prejoinModule.getDAOData();

        assert(toRepool > 0);
        assertEq(usdc.balanceOf(rePoolAddress), 0);

        vm.prank(daoAdmin);
        prejoinModule.transferToRepool();

        (, , , , , , , , , uint256 newRepoolBalance, ) = prejoinModule.getDAOData();

        assertEq(newRepoolBalance, 0);
        assertEq(usdc.balanceOf(rePoolAddress), toRepool);
    }
}
