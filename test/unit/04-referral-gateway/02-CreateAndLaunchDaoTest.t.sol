// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

contract ReferralGatewayCreateAndLaunchDaoTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    address referralGatewayAddress;
    address takadao;
    address daoAdmin;
    address notAllowedAddress = makeAddr("notAllowedAddress");
    address DAO = makeAddr("DAO");
    address subscriptionModule = makeAddr("subscriptionModule");
    string tDaoName = "The LifeDao";

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (, bmConsumerMock, , referralGatewayAddress, , , , , , , , helperConfig) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        daoAdmin = config.daoMultisig;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(referralGatewayAddress);
    }

    function testCreateANewDao() public {
        vm.prank(notAllowedAddress);
        vm.expectRevert();
        referralGateway.createDAO(true, true, (block.timestamp + 31_536_000), 100e6);

        vm.prank(takadao);
        referralGateway.createDAO(true, true, (block.timestamp + 31_536_000), 100e6);

        (
            bool prejoinEnabled,
            ,
            address DAOAdmin,
            address DAOAddress,
            uint256 launchDate,
            uint256 objectiveAmount,
            uint256 currentAmount,
            ,
            ,
            ,

        ) = referralGateway.getDAOData();

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

    modifier createDao() {
        vm.startPrank(takadao);
        referralGateway.setDaoName(tDaoName);
        referralGateway.createDAO(true, true, 1743479999, 1e12);
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

        ) = referralGateway.getDAOData();

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

        ) = referralGateway.getDAOData();

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

        (, referralDiscount, , , , , , , , , ) = referralGateway.getDAOData();

        assert(!referralDiscount);

        address newRePoolAddress = makeAddr("rePoolAddress");

        vm.prank(daoAdmin);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.enableRepool(address(0));

        vm.prank(daoAdmin);
        referralGateway.enableRepool(newRePoolAddress);

        (, , , , , , , , rePoolAddress, , ) = referralGateway.getDAOData();

        assertEq(rePoolAddress, newRePoolAddress);
    }
}
