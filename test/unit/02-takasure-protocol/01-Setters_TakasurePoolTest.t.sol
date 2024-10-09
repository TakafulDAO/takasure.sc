// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";

contract Setters_TakasureReserveTest is StdCheats, Test {
    TestDeployTakasureReserve deployer;
    DeployConsumerMocks mockDeployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    JoinModule joinModule;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address joinModuleAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC

    function setUp() public {
        deployer = new TestDeployTakasureReserve();
        (
            takasureReserveProxy,
            joinModuleAddress,
            ,
            contributionTokenAddress,
            helperConfig
        ) = deployer.run();

        joinModule = JoinModule(joinModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;

        mockDeployer = new DeployConsumerMocks();
        bmConsumerMock = mockDeployer.run();

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(takasureReserve), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(joinModuleAddress));

        vm.prank(config.takadaoOperator);
        joinModule.updateBmAddress();
    }

    /// @dev Test the owner can set a new service fee
    function testTakasureReserve_setNewServiceFeeToNewValue() public {
        assert(2 + 2 == 4);
        uint8 newServiceFee = 35;

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(takasureReserve));
        emit TakasureEvents.OnServiceFeeChanged(newServiceFee);
        takasureReserve.setNewServiceFee(newServiceFee);

        uint8 serviceFee = takasureReserve.getReserveValues().serviceFee;

        assertEq(newServiceFee, serviceFee);
    }

    /// @dev Test the owner can set a new minimum threshold
    function testTakasureReserve_setNewMinimumThreshold() public {
        uint256 newMinimumThreshold = 50e6;

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(takasureReserve));
        emit TakasureEvents.OnNewMinimumThreshold(newMinimumThreshold);
        takasureReserve.setNewMinimumThreshold(newMinimumThreshold);

        assertEq(newMinimumThreshold, takasureReserve.getReserveValues().minimumThreshold);
    }

    /// @dev Test the owner can set a new minimum threshold
    function testTakasureReserve_setNewMaximumThreshold() public {
        uint256 newMaximumThreshold = 50e6;

        vm.prank(admin);
        vm.expectEmit(true, false, false, false, address(takasureReserve));
        emit TakasureEvents.OnNewMaximumThreshold(newMaximumThreshold);
        takasureReserve.setNewMaximumThreshold(newMaximumThreshold);

        assertEq(newMaximumThreshold, takasureReserve.getReserveValues().maximumThreshold);
    }

    /// @dev Test the owner can set a new contribution token
    function testTakasureReserve_setNewContributionToken() public {
        vm.prank(admin);
        takasureReserve.setNewContributionToken(alice);

        assertEq(alice, takasureReserve.getReserveValues().contributionToken);
    }

    /// @dev Test the owner can set a new service claim address
    function testTakasureReserve_cansetNewServiceClaimAddress() public {
        vm.prank(admin);
        takasureReserve.setNewFeeClaimAddress(alice);

        assertEq(alice, takasureReserve.feeClaimAddress());
    }

    /// @dev Test the owner can set custom duration
    function testTakasureReserve_setAllowCustomDuration() public {
        vm.prank(admin);
        takasureReserve.setAllowCustomDuration(true);

        assertEq(true, takasureReserve.getReserveValues().allowCustomDuration);
    }

    function testTakasureReserve_setKYCstatus() public {
        assert(!takasureReserve.getMemberFromAddress(alice).isKYCVerified);

        vm.prank(kycService);
        vm.expectEmit(true, false, false, false, address(joinModule));
        emit TakasureEvents.OnMemberKycVerified(1, alice);
        joinModule.setKYCStatus(alice);

        assert(takasureReserve.getMemberFromAddress(alice).isKYCVerified);
    }
}
