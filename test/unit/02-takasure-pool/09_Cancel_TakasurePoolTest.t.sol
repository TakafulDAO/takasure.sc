// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/libraries/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Refund_TakasurePoolTest is StdCheats, Test, SimulateDonResponse {
    TestDeployTakasure deployer;
    DeployConsumerMocks mockDeployer;
    TakasurePool takasurePool;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    address proxy;
    address contributionTokenAddress;
    address admin;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployTakasure();
        (, proxy, contributionTokenAddress, helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;

        mockDeployer = new DeployConsumerMocks();
        bmConsumerMock = mockDeployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        vm.prank(admin);
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConsumerMock));

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(takasurePool));

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank;

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(admin);
        takasurePool.setKYCStatus(alice);
        vm.stopPrank();

        vm.warp(block.timestamp + YEAR + 31 days);
        vm.roll(block.number + 1);

        takasurePool.defaultMember(alice);
    }

    function testTakasurePool_cancelMembership() public {
        Member memory Alice = takasurePool.getMemberFromAddress(alice);
        assert(Alice.memberState == MemberState.Defaulted);

        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit TakasureEvents.OnMemberCanceled(Alice.memberId, alice);
        takasurePool.cancelMembership(alice);

        Alice = takasurePool.getMemberFromAddress(alice);
        assert(Alice.memberState == MemberState.Canceled);
    }
}