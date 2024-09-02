// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {Reserve, Member} from "contracts/types/TakasureTypes.sol";

contract Setters_TakasurePoolTest is StdCheats, Test {
    TestDeployTakasure deployer;
    DeployConsumerMocks mockDeployer;
    TakasurePool takasurePool;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConnsumerMock;
    address proxy;
    address contributionTokenAddress;
    address admin;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployTakasure();
        (, proxy, contributionTokenAddress, helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;

        mockDeployer = new DeployConsumerMocks();
        bmConnsumerMock = mockDeployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        vm.startPrank(alice);
        usdc.mintUSDC(alice, USDC_INITIAL_AMOUNT);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(admin);
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConnsumerMock));

        vm.prank(msg.sender);
        bmConnsumerMock.setNewRequester(address(takasurePool));
    }

    /// @dev Test the owner can set a new service fee
    function testTakasurePool_setNewServiceFeeToNewValue() public {
        uint8 newServiceFee = 35;

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(takasurePool));
        emit TakasureEvents.OnServiceFeeChanged(newServiceFee);
        takasurePool.setNewServiceFee(newServiceFee);

        Reserve memory reserve = takasurePool.getReserveValues();
        uint8 serviceFee = reserve.serviceFee;

        assertEq(newServiceFee, serviceFee);
    }

    /// @dev Test the owner can set a new minimum threshold
    function testTakasurePool_setNewMinimumThreshold() public {
        uint256 newMinimumThreshold = 50e6;

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(takasurePool));
        emit TakasureEvents.OnNewMinimumThreshold(newMinimumThreshold);
        takasurePool.setNewMinimumThreshold(newMinimumThreshold);
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
        vm.expectEmit(true, false, false, false, address(takasurePool));
        emit TakasureEvents.OnNewFeeClaimAddress(alice);
        takasurePool.setNewFeeClaimAddress(alice);
    }

    /// @dev Test the owner can set custom duration
    function testTakasurePool_setAllowCustomDuration() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(takasurePool));
        emit TakasureEvents.OnAllowCustomDuration(true);
        takasurePool.setAllowCustomDuration(true);
    }

    function testTakasurePool_setKYCstatus() public {
        Member memory member = takasurePool.getMemberFromAddress(alice);
        bool getMemberKYCstatusBefore = member.isKYCVerified;

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(takasurePool));
        emit TakasureEvents.OnMemberKycVerified(1, alice);
        takasurePool.setKYCStatus(alice);

        member = takasurePool.getMemberFromAddress(alice);
        bool getMemberKYCstatusAfter = member.isKYCVerified;

        assert(!getMemberKYCstatusBefore);
        assert(getMemberKYCstatusAfter);
    }
}
