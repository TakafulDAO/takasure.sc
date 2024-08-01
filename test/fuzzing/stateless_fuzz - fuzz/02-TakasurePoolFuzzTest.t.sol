// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "scripts/DeployTokenAndPool.s.sol";
import {DeployConsumerMocks} from "scripts/DeployConsumerMocks.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMockSuccess} from "test/mocks/BenefitMultiplierConsumerMockSuccess.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract TakasurePoolFuzzTest is Test {
    DeployTokenAndPool deployer;
    DeployConsumerMocks mockDeployer;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;
    address contributionTokenAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    event MemberJoined(address indexed member, uint256 indexed contributionAmount);

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (, proxy, , , contributionTokenAddress, ) = deployer.run();

        mockDeployer = new DeployConsumerMocks();
        (
            ,
            ,
            BenefitMultiplierConsumerMockSuccess bmConsumerSuccess,
            address bmDeployer
        ) = mockDeployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);

        vm.prank(takasurePool.owner());
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConsumerSuccess));

        vm.prank(bmDeployer);
        bmConsumerSuccess.setNewRequester(address(takasurePool));
    }

    function test_fuzz_ownerCanSetKycstatus(address notOwner) public {
        // The input address must not be the same as the takasurePool address
        vm.assume(notOwner != takasurePool.owner());

        vm.prank(alice);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        vm.prank(notOwner);
        vm.expectRevert();
        takasurePool.setKYCStatus(alice);
    }
}
