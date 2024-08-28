// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract TakasurePoolFuzzTest is Test {
    TestDeployTakasure deployer;
    DeployConsumerMocks mockDeployer;
    TakasurePool takasurePool;
    HelperConfig helperConfig;
    address proxy;
    address contributionTokenAddress;
    address daoMultisig;
    address takadao;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    event MemberJoined(address indexed member, uint256 indexed contributionAmount);

    function setUp() public {
        deployer = new TestDeployTakasure();
        (, proxy, contributionTokenAddress, helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        daoMultisig = config.daoMultisig;
        takadao = config.takadaoOperator;

        mockDeployer = new DeployConsumerMocks();
        BenefitMultiplierConsumerMock bmConnsumerMock = mockDeployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);

        vm.prank(daoMultisig);
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConnsumerMock));

        vm.prank(msg.sender);
        bmConnsumerMock.setNewRequester(address(takasurePool));
    }

    function test_fuzz_ownerCanSetKycstatus(address notOwner) public {
        // The input address must not be the same as the takasurePool address
        vm.assume(notOwner != daoMultisig);

        vm.prank(alice);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        vm.prank(notOwner);
        vm.expectRevert();
        takasurePool.setKYCStatus(alice);
    }

    function test_fuzz_onlyDaoAndTakadaoCanSetNewBenefitMultiplier(address notAuthorized) public {
        vm.assume(notAuthorized != daoMultisig && notAuthorized != takadao);

        vm.prank(notAuthorized);
        vm.expectRevert();
        takasurePool.setNewBenefitMultiplierConsumer(alice);
    }
}
