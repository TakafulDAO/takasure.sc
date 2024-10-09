// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {MembersModule} from "contracts/takasure/modules/MembersModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract TakasureReserveFuzzTest is Test {
    TestDeployTakasureReserve deployer;
    DeployConsumerMocks mockDeployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    JoinModule joinModule;
    MembersModule membersModule;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address daoMultisig;
    address takadao;
    address joinModuleAddress;
    address membersModuleAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployTakasureReserve();
        (
            takasureReserveProxy,
            joinModuleAddress,
            membersModuleAddress,
            contributionTokenAddress,
            helperConfig
        ) = deployer.run();

        joinModule = JoinModule(joinModuleAddress);
        membersModule = MembersModule(membersModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        daoMultisig = config.daoMultisig;
        takadao = config.takadaoOperator;

        mockDeployer = new DeployConsumerMocks();
        BenefitMultiplierConsumerMock bmConsumerMock = mockDeployer.run();

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(daoMultisig);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(joinModuleAddress));

        vm.prank(takadao);
        joinModule.updateBmAddress();
    }

    function test_fuzz_ownerCanSetKycstatus(address notOwner) public {
        vm.assume(notOwner != daoMultisig);

        vm.prank(alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        vm.prank(notOwner);
        vm.expectRevert();
        joinModule.setKYCStatus(alice);
    }

    function test_fuzz_onlyDaoAndTakadaoCanSetNewBenefitMultiplier(address notAuthorized) public {
        vm.assume(notAuthorized != daoMultisig && notAuthorized != takadao);

        vm.prank(notAuthorized);
        vm.expectRevert();
        takasureReserve.setNewBenefitMultiplierConsumerAddress(alice);
    }
}
