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
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

contract RevertsPrejoinModuleTest is Test {
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

    function testSetNewContributionToken() public {
        assertEq(address(prejoinModule.usdc()), usdcAddress);

        address newUSDC = makeAddr("newUSDC");

        vm.prank(daoAdmin);
        prejoinModule.setUsdcAddress(newUSDC);

        assertEq(address(prejoinModule.usdc()), newUSDC);
    }

    /*//////////////////////////////////////////////////////////////
                               CREATE DAO
    //////////////////////////////////////////////////////////////*/
    function testCreateANewDao() public {
        vm.prank(referral);
        vm.expectRevert();
        prejoinModule.createDAO(
            tDaoName,
            true,
            true,
            (block.timestamp + 31_536_000),
            100e6,
            address(bmConsumerMock)
        );

        vm.startPrank(takadao);
        prejoinModule.createDAO(
            tDaoName,
            true,
            true,
            (block.timestamp + 31_536_000),
            100e6,
            address(bmConsumerMock)
        );
        prejoinModule.setDAOName(tDaoName);
        vm.stopPrank();

        (
            bool prejoinEnabled,
            ,
            address DAOAddress,
            uint256 launchDate,
            uint256 objectiveAmount,
            uint256 currentAmount,
            ,
            ,
            ,

        ) = prejoinModule.getDAOData();

        assertEq(prejoinEnabled, true);
        assertEq(DAOAddress, address(0));
        assertEq(launchDate, block.timestamp + 31_536_000);
        assertEq(objectiveAmount, 100e6);
        assertEq(currentAmount, 0);

        vm.prank(referral);
        vm.expectRevert();
        prejoinModule.updateLaunchDate(block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        prejoinModule.updateLaunchDate(block.timestamp + 32_000_000);
    }

    modifier createDao() {
        vm.startPrank(daoAdmin);
        prejoinModule.createDAO(tDaoName, true, true, 1743479999, 1e12, address(bmConsumerMock));
        prejoinModule.setDAOName(tDaoName);
        vm.stopPrank();
        _;
    }

    function testMustRevertIfprepaymentContributionIsOutOfRange() public createDao {
        // 24.99 USDC
        vm.startPrank(child);
        vm.expectRevert(PrejoinModule.PrejoinModule__ContributionOutOfRange.selector);
        prejoinModule.payContribution(2499e4, referral);

        // 250.01 USDC
        vm.expectRevert(PrejoinModule.PrejoinModule__ContributionOutOfRange.selector);
        prejoinModule.payContribution(25001e4, referral);
        vm.stopPrank();
    }
}
