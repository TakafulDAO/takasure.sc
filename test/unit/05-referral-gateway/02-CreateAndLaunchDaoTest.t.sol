// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {DaoDataReader, IReferralGateway} from "test/helpers/lowLevelCall/DaoDataReader.sol";

contract ReferralGatewayCreateAndLaunchDaoTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    address referralGatewayAddress;
    address takadao;
    address daoAdmin;
    address pauseGuardian;
    address notAllowedAddress = makeAddr("notAllowedAddress");
    address DAO = makeAddr("DAO");
    address subscriptionModule = makeAddr("subscriptionModule");

    modifier pauseContract() {
        vm.prank(pauseGuardian);
        referralGateway.pause();
        _;
    }

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (, referralGatewayAddress, , , , , , , , helperConfig) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        daoAdmin = config.daoMultisig;
        pauseGuardian = config.pauseGuardian;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
    }

    function testCreateANewDao() public {
        vm.prank(notAllowedAddress);
        vm.expectRevert();
        referralGateway.createDAO(true, true, (block.timestamp + 31_536_000), 100e6);

        vm.prank(takadao);
        referralGateway.createDAO(true, true, (block.timestamp + 31_536_000), 100e6);

        bool prejoinEnabled = DaoDataReader.getBool(IReferralGateway(address(referralGateway)), 0);
        address DAOAdmin = DaoDataReader.getAddress(IReferralGateway(address(referralGateway)), 3);
        address DAOAddress = DaoDataReader.getAddress(
            IReferralGateway(address(referralGateway)),
            4
        );
        uint256 launchDate = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 5);
        uint256 objectiveAmount = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            6
        );
        uint256 currentAmount = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            7
        );

        assertEq(prejoinEnabled, true);
        assertEq(DAOAdmin, daoAdmin);
        assertEq(DAOAddress, address(0));
        assertEq(launchDate, block.timestamp + 31_536_000);
        assertEq(objectiveAmount, 100e6);
        assertEq(currentAmount, 0);

        vm.prank(takadao);
        vm.expectRevert(ReferralGateway.ReferralGateway__InvalidLaunchDate.selector);
        referralGateway.createDAO(true, true, 0, 100e6);

        vm.prank(notAllowedAddress);
        vm.expectRevert();
        referralGateway.updateLaunchDate(block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        referralGateway.updateLaunchDate(block.timestamp + 32_000_000);
    }

    function testCreateANewDaoRevertIfContractPaused() public pauseContract {
        vm.prank(takadao);
        vm.expectRevert();
        referralGateway.createDAO(true, true, (block.timestamp + 31_536_000), 100e6);
    }

    modifier createDao() {
        vm.startPrank(takadao);
        referralGateway.createDAO(true, true, 1743479999, 1e12);
        vm.stopPrank();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                   LAUNCH DAO
        //////////////////////////////////////////////////////////////*/

    function testLaunchDAO() public createDao {
        bool prejoinEnabled = DaoDataReader.getBool(IReferralGateway(address(referralGateway)), 0);
        bool referralDiscount = DaoDataReader.getBool(
            IReferralGateway(address(referralGateway)),
            1
        );
        address DAOAdmin = DaoDataReader.getAddress(IReferralGateway(address(referralGateway)), 3);
        address DAOAddress = DaoDataReader.getAddress(
            IReferralGateway(address(referralGateway)),
            4
        );
        uint256 launchDate = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 5);
        uint256 objectiveAmount = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            6
        );
        uint256 currentAmount = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            7
        );
        address rePoolAddress = DaoDataReader.getAddress(
            IReferralGateway(address(referralGateway)),
            9
        );

        assertEq(DAOAddress, address(0));
        assertEq(prejoinEnabled, true);
        assertEq(referralDiscount, true);

        vm.prank(notAllowedAddress);
        vm.expectRevert();
        referralGateway.launchDAO(DAO, subscriptionModule, true);

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.launchDAO(address(0), subscriptionModule, true);

        vm.prank(daoAdmin);
        referralGateway.launchDAO(DAO, subscriptionModule, true);

        prejoinEnabled = DaoDataReader.getBool(IReferralGateway(address(referralGateway)), 0);
        referralDiscount = DaoDataReader.getBool(IReferralGateway(address(referralGateway)), 1);
        DAOAdmin = DaoDataReader.getAddress(IReferralGateway(address(referralGateway)), 3);
        DAOAddress = DaoDataReader.getAddress(IReferralGateway(address(referralGateway)), 4);
        launchDate = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 5);
        objectiveAmount = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 6);
        currentAmount = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 7);
        rePoolAddress = DaoDataReader.getAddress(IReferralGateway(address(referralGateway)), 9);

        assertEq(DAOAddress, DAO);
        assert(!prejoinEnabled);
        assert(referralDiscount);
        assertEq(rePoolAddress, address(0));

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__DAOAlreadyLaunched.selector);
        referralGateway.updateLaunchDate(block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__DAOAlreadyLaunched.selector);
        referralGateway.launchDAO(DAO, subscriptionModule, true);

        vm.prank(daoAdmin);
        referralGateway.switchReferralDiscount();

        referralDiscount = DaoDataReader.getBool(IReferralGateway(address(referralGateway)), 1);

        assert(!referralDiscount);

        address newRePoolAddress = makeAddr("rePoolAddress");

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.enableRepool(address(0));

        vm.prank(daoAdmin);
        referralGateway.enableRepool(newRePoolAddress);

        rePoolAddress = DaoDataReader.getAddress(IReferralGateway(address(referralGateway)), 9);

        assertEq(rePoolAddress, newRePoolAddress);
    }
}
