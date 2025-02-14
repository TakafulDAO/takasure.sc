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

contract LaunchDaoPrejoinModuleTest is Test {
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

    bytes32 public constant REFERRAL = keccak256("REFERRAL");

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

    /*//////////////////////////////////////////////////////////////
                                   LAUNCH DAO
        //////////////////////////////////////////////////////////////*/

    function testLaunchDAO() public createDao {
        (
            bool prejoinEnabled,
            bool referralDiscount,
            address DAOAdmin,
            address DAOAddress,
            uint256 launchDate,
            uint256 objectiveAmount,
            uint256 currentAmount,
            ,
            address rePoolAddress,
            ,

        ) = prejoinModule.getDAOData();

        assertEq(DAOAddress, address(0));
        assertEq(prejoinEnabled, true);
        assertEq(referralDiscount, true);

        vm.prank(referral);
        vm.expectRevert(PrejoinModule.PrejoinModule__onlyDAOAdmin.selector);
        prejoinModule.launchDAO(address(takasureReserve), entryModuleAddress, true);

        vm.prank(daoAdmin);
        vm.expectRevert(AddressCheck.TakasureProtocol__ZeroAddress.selector);
        prejoinModule.launchDAO(address(0), entryModuleAddress, true);

        vm.prank(daoAdmin);
        vm.expectRevert(AddressCheck.TakasureProtocol__ZeroAddress.selector);
        prejoinModule.launchDAO(address(takasureReserve), address(0), true);

        vm.prank(daoAdmin);
        prejoinModule.launchDAO(address(takasureReserve), entryModuleAddress, true);

        (
            prejoinEnabled,
            referralDiscount,
            DAOAdmin,
            DAOAddress,
            launchDate,
            objectiveAmount,
            currentAmount,
            ,
            rePoolAddress,
            ,

        ) = prejoinModule.getDAOData();

        assertEq(DAOAddress, address(takasureReserve));
        assert(!prejoinEnabled);
        assert(referralDiscount);
        assertEq(rePoolAddress, address(0));

        vm.prank(daoAdmin);
        vm.expectRevert(PrejoinModule.PrejoinModule__DAOAlreadyLaunched.selector);
        prejoinModule.updateLaunchDate(block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        vm.expectRevert(PrejoinModule.PrejoinModule__WrongModuleState.selector);
        prejoinModule.launchDAO(address(takasureReserve), entryModuleAddress, true);

        vm.prank(daoAdmin);
        prejoinModule.switchReferralDiscount();

        (, referralDiscount, , , , , , , , , ) = prejoinModule.getDAOData();

        assert(!referralDiscount);

        address newRePoolAddress = makeAddr("rePoolAddress");

        vm.prank(daoAdmin);
        vm.expectRevert(AddressCheck.TakasureProtocol__ZeroAddress.selector);
        prejoinModule.enableRepool(address(0));

        vm.prank(daoAdmin);
        prejoinModule.enableRepool(newRePoolAddress);

        (, , , , , , , , rePoolAddress, , ) = prejoinModule.getDAOData();

        assertEq(rePoolAddress, newRePoolAddress);
    }
}
