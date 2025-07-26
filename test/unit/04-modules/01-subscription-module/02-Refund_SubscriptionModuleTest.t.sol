// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {ReferralRewardsModule} from "contracts/modules/ReferralRewardsModule.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {AssociationMember, AssociationMemberState} from "contracts/types/TakasureTypes.sol";

contract Refund_SubscriptionModuleTest is StdCheats, Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    AddAddressesAndRoles addressesAndRoles;
    KYCModule kycModule;
    SubscriptionModule subscriptionModule;
    ReferralRewardsModule referralRewardsModule;
    address takadao;
    address couponRedeemer;
    address feeClaimAddress;
    address kycProvider;
    address couponPool;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 150 USDC
    uint256 public constant SUBSCRIPTION = 25e6; // 25 USDC
    uint256 public constant FEE = 27; // 27% fee

    event OnRefund(uint256 indexed memberId, address indexed member, uint256 indexed amount);

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addressManager,
            ModuleManager moduleManager
        ) = managersDeployer.run();
        (
            address operator,
            ,
            address kyc,
            address redeemer,
            address feeClaimer,
            address pool
        ) = addressesAndRoles.run(addressManager, config, address(moduleManager));
        (, , kycModule, , referralRewardsModule, , subscriptionModule) = moduleDeployer.run(
            addressManager
        );

        // kycService = config.kycProvider;
        takadao = operator;
        couponRedeemer = redeemer;
        feeClaimAddress = feeClaimer;
        kycProvider = kyc;
        couponPool = pool;

        usdc = IUSDC(config.contributionToken);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
        deal(address(usdc), bob, USDC_INITIAL_AMOUNT);
        deal(address(usdc), couponPool, USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);

        vm.prank(bob);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);

        vm.prank(couponPool);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
    }

    modifier payAndKyc() {
        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

        vm.prank(kycProvider);
        kycModule.approveKYC(alice);

        _;
    }

    function testSubscriptionModule_refundUpdatesMember() public payAndKyc {
        AssociationMember memory aliceAsMember = subscriptionModule.getAssociationMember(alice);

        assert(!aliceAsMember.isRefunded);

        vm.prank(takadao);
        subscriptionModule.refund(alice);

        aliceAsMember = subscriptionModule.getAssociationMember(alice);
        assert(aliceAsMember.isRefunded);
    }

    function testSubscriptionModule_refundTransferAmountsIfThereIsNoCoupon() public payAndKyc {
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 contractBalanceBefore = usdc.balanceOf(address(subscriptionModule));
        uint256 couponPoolBalanceBefore = usdc.balanceOf(couponPool);

        vm.prank(takadao);
        subscriptionModule.refund(alice);

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        uint256 contractBalanceAfter = usdc.balanceOf(address(subscriptionModule));
        uint256 couponPoolBalanceAfter = usdc.balanceOf(couponPool);

        assertEq(aliceBalanceAfter, aliceBalanceBefore + SUBSCRIPTION - (SUBSCRIPTION * FEE) / 100);
        assertEq(
            contractBalanceBefore,
            contractBalanceAfter + SUBSCRIPTION - (SUBSCRIPTION * FEE) / 100
        );
        assertEq(contractBalanceAfter, 0);
        assertEq(couponPoolBalanceAfter, couponPoolBalanceBefore);
    }

    function testSubscriptionModule_refundTransferAmountsIfThereIsCoupon() public {
        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(
            alice,
            address(0),
            SUBSCRIPTION,
            block.timestamp
        );

        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 contractBalanceBefore = usdc.balanceOf(address(subscriptionModule));
        uint256 couponPoolBalanceBefore = usdc.balanceOf(couponPool);

        vm.prank(takadao);
        subscriptionModule.refund(alice);

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        uint256 contractBalanceAfter = usdc.balanceOf(address(subscriptionModule));
        uint256 couponPoolBalanceAfter = usdc.balanceOf(couponPool);

        assertEq(aliceBalanceAfter, aliceBalanceBefore);
        assertEq(
            contractBalanceBefore,
            contractBalanceAfter + SUBSCRIPTION - (SUBSCRIPTION * FEE) / 100
        );
        assertEq(contractBalanceAfter, 0);
        assertEq(
            couponPoolBalanceAfter,
            couponPoolBalanceBefore + SUBSCRIPTION - (SUBSCRIPTION * FEE) / 100
        );
    }

    function testSubscriptionModule_refundEmitsEvent() public payAndKyc {
        vm.prank(takadao);
        vm.expectEmit(true, true, true, false, address(subscriptionModule));
        emit OnRefund(1, alice, SUBSCRIPTION - (SUBSCRIPTION * FEE) / 100);
        subscriptionModule.refund(alice);
    }
}
