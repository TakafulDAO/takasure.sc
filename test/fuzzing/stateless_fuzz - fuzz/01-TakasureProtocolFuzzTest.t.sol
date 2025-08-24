// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract TakasureProtocolFuzzTest is Test {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    SubscriptionModule subscriptionModule;
    KYCModule kycModule;
    MemberModule memberModule;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address daoMultisig;
    address takadao;
    address subscriptionModuleAddress;
    address kycModuleAddress;
    address memberModuleAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public parent = makeAddr("parent");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;
    uint256 public constant BM = 1;

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            takasureReserveProxy,
            ,
            subscriptionModuleAddress,
            kycModuleAddress,
            memberModuleAddress,
            ,
            ,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        subscriptionModule = SubscriptionModule(subscriptionModuleAddress);
        kycModule = KYCModule(kycModuleAddress);
        memberModule = MemberModule(memberModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        daoMultisig = config.daoMultisig;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(memberModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
    }

    function test_fuzz_ownerCanapproveKYC(address notOwner) public {
        vm.assume(notOwner != daoMultisig);

        vm.prank(alice);
        subscriptionModule.paySubscription(alice, parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        vm.prank(notOwner);
        vm.expectRevert();
        kycModule.approveKYC(alice, BM);
    }
}
