// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

contract ReferralGatewayCreateAndLaunchDaoTest is Test {
    TestDeployTakasureReserve deployer;
    ReferralGateway referralGateway;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    address referralGatewayAddress;
    address takadao;
    address daoAdmin;

    function setUp() public {
        // Deployer
        deployer = new TestDeployTakasureReserve();
        // Deploy contracts
        (, bmConsumerMock, , , , , , referralGatewayAddress, , , helperConfig) = deployer.run();

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
        address nonAllowedAddress = makeAddr("nonAllowedAddress");

        vm.prank(nonAllowedAddress);
        vm.expectRevert();
        referralGateway.createDAO(
            true,
            true,
            (block.timestamp + 31_536_000),
            100e6,
            address(bmConsumerMock)
        );

        vm.prank(takadao);
        referralGateway.createDAO(
            true,
            true,
            (block.timestamp + 31_536_000),
            100e6,
            address(bmConsumerMock)
        );

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
        referralGateway.createDAO(true, true, 0, 100e6, address(bmConsumerMock));

        vm.prank(nonAllowedAddress);
        vm.expectRevert();
        referralGateway.updateLaunchDate(block.timestamp + 32_000_000);

        vm.prank(daoAdmin);
        referralGateway.updateLaunchDate(block.timestamp + 32_000_000);
    }
}
