// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";

contract Setters_TakasurePoolTest is StdCheats, Test {
    TestDeployTakasure deployer;
    DeployConsumerMocks mockDeployer;
    TakasurePool takasurePool;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    address proxy;
    address admin;
    address public alice = makeAddr("alice");

    function setUp() public {
        deployer = new TestDeployTakasure();
        (, proxy, , helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;

        mockDeployer = new DeployConsumerMocks();
        bmConsumerMock = mockDeployer.run();

        takasurePool = TakasurePool(address(proxy));

        vm.prank(admin);
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConsumerMock));

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(takasurePool));
    }

    /// @dev Test the owner can set a new service fee
    function testTakasurePool_setNewServiceFeeToNewValue() public {
        uint8 newServiceFee = 35;

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(takasurePool));
        emit TakasureEvents.OnServiceFeeChanged(newServiceFee);
        takasurePool.setNewServiceFee(newServiceFee);

        (, , , , , , , , , uint8 serviceFee, , ) = takasurePool.getReserveValues();

        assertEq(newServiceFee, serviceFee);
    }

    /// @dev Test the owner can set a new minimum threshold
    function testTakasurePool_setNewMinimumThreshold() public {
        uint256 newThreshold = 50e6;

        vm.prank(admin);
        takasurePool.setNewMinimumThreshold(newThreshold);

        assertEq(newThreshold, takasurePool.minimumThreshold());
    }

    /// @dev Test the owner can set a new contribution token
    function testTakasurePool_setNewContributionToken() public {
        vm.prank(admin);
        takasurePool.setNewContributionToken(alice);

        assertEq(alice, takasurePool.getContributionTokenAddress());
    }

    /// @dev Test the owner can set a new service claim address
    function testTakasurePool_cansetNewServiceClaimAddress() public {
        vm.prank(admin);
        takasurePool.setNewFeeClaimAddress(alice);

        assertEq(alice, takasurePool.feeClaimAddress());
    }

    /// @dev Test the owner can set custom duration
    function testTakasurePool_setAllowCustomDuration() public {
        vm.prank(admin);
        takasurePool.setAllowCustomDuration(true);

        assertEq(true, takasurePool.allowCustomDuration());
    }

    function testTakasurePool_setKYCstatus() public {
        bool getMemberKYCstatusBefore = takasurePool.getMemberKYCStatus(alice);

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(takasurePool));
        emit TakasureEvents.OnMemberKycVerified(1, alice);
        takasurePool.setKYCStatus(alice);

        bool getMemberKYCstatusAfter = takasurePool.getMemberKYCStatus(alice);

        assert(!getMemberKYCstatusBefore);
        assert(getMemberKYCstatusAfter);
    }
}
