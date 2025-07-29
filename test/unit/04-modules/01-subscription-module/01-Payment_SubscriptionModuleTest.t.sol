// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {DeployReserve} from "test/utils/05-DeployReserve.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {ReferralRewardsModule} from "contracts/modules/ReferralRewardsModule.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {AssociationMember, AssociationMemberState, ProtocolAddressType} from "contracts/types/TakasureTypes.sol";

contract Payment_SubscriptionModuleTest is StdCheats, Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    DeployReserve reserveDeployer;
    AddAddressesAndRoles addressesAndRoles;
    KYCModule kycModule;
    SubscriptionModule subscriptionModule;
    ReferralRewardsModule referralRewardsModule;
    TakasureReserve takasureReserve;
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
    uint256 public constant REFERRAL_RESERVE = 5; // 5%

    event OnNewAssociationMember(
        uint256 indexed memberId,
        address indexed memberWallet,
        address indexed parentWallet
    );
    event OnCouponRedeemed(address indexed member, uint256 indexed couponAmount);

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        reserveDeployer = new DeployReserve();
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
        takasureReserve = reserveDeployer.run(config, addressManager);

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

    function testSubscriptionModule_paySubscriptionOnBehalfOfEmitsEvent() public {
        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, true, false, address(subscriptionModule));
        emit OnNewAssociationMember(1, alice, address(0));
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);
    }

    function testSubscriptionModule_paySubscriptionOnBehalfOfCreatesANewAssociationMember() public {
        AssociationMember memory aliceAsMember = subscriptionModule.getAssociationMember(alice);

        assertEq(aliceAsMember.memberId, 0);
        assertEq(aliceAsMember.discount, 0);
        assertEq(aliceAsMember.associateStartTime, 0);
        assertEq(aliceAsMember.wallet, address(0));
        assertEq(aliceAsMember.parent, address(0));
        assert(aliceAsMember.memberState == AssociationMemberState.Inactive);
        assert(!aliceAsMember.isRefunded);
        assert(!aliceAsMember.isLifeProtected);
        assert(!aliceAsMember.isFarewellProtected);

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

        aliceAsMember = subscriptionModule.getAssociationMember(alice);

        assertEq(aliceAsMember.memberId, 1);
        assertEq(aliceAsMember.discount, 0);
        assertEq(aliceAsMember.associateStartTime, block.timestamp);
        assertEq(aliceAsMember.wallet, alice);
        assertEq(aliceAsMember.parent, address(0));
        assert(aliceAsMember.memberState == AssociationMemberState.Inactive);
        assert(!aliceAsMember.isRefunded);
        assert(!aliceAsMember.isLifeProtected);
        assert(!aliceAsMember.isFarewellProtected);
    }

    function testSubscriptionModule_paySubscriptionOnBehalfOfTransferTheCorrespondingAmounts()
        public
    {
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 feeClaimAddressBalanceBefore = usdc.balanceOf(feeClaimAddress);
        uint256 contractBalanceBefore = usdc.balanceOf(address(subscriptionModule));
        uint256 referralCotractBalanceBefore = usdc.balanceOf(address(referralRewardsModule));

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        uint256 feeClaimAddressBalanceAfter = usdc.balanceOf(feeClaimAddress);
        uint256 contractBalanceAfter = usdc.balanceOf(address(subscriptionModule));
        uint256 referralCotractBalanceAfter = usdc.balanceOf(address(referralRewardsModule));

        assertEq(aliceBalanceAfter, aliceBalanceBefore - SUBSCRIPTION);
        assertEq(
            feeClaimAddressBalanceAfter,
            feeClaimAddressBalanceBefore + ((SUBSCRIPTION * (FEE - REFERRAL_RESERVE)) / 100)
        );
        assertEq(
            contractBalanceAfter,
            contractBalanceBefore + SUBSCRIPTION - (SUBSCRIPTION * FEE) / 100
        );
        assertEq(
            referralCotractBalanceAfter,
            referralCotractBalanceBefore + (SUBSCRIPTION * REFERRAL_RESERVE) / 100
        );
    }

    modifier payAndKyc() {
        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

        vm.prank(kycProvider);
        kycModule.approveKYC(alice);

        _;
    }

    function testSubscriptionModule_paySubscriptionOnBehalfOfAssignParentAndDiscountCorrectly()
        public
        payAndKyc
    {
        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(bob, alice, 0, block.timestamp);

        AssociationMember memory bobAsMember = subscriptionModule.getAssociationMember(bob);

        assertEq(bobAsMember.discount, (SUBSCRIPTION * REFERRAL_RESERVE) / 100);
        assertEq(bobAsMember.parent, alice);
    }

    function testSubscriptionModule_paySubscriptionOnBehalfAssignsRewardsCorrectly()
        public
        payAndKyc
    {
        assertEq(referralRewardsModule.parentRewardsByChild(alice, bob), 0);
        assertEq(referralRewardsModule.parentRewardsByLayer(alice, 1), 0);

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(bob, alice, 0, block.timestamp);

        assertEq(referralRewardsModule.parentRewardsByChild(alice, bob), (SUBSCRIPTION * 4) / 100);
        assertEq(referralRewardsModule.parentRewardsByLayer(alice, 1), (SUBSCRIPTION * 4) / 100);
    }

    function testSubscriptionModule_paySubscriptionOnBehalfOfCalculateAmountsAfterCouponsCorrectly()
        public
    {
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);
        uint256 feeClaimAddressBalanceBefore = usdc.balanceOf(feeClaimAddress);
        uint256 contractBalanceBefore = usdc.balanceOf(address(subscriptionModule));
        uint256 referralCotractBalanceBefore = usdc.balanceOf(address(referralRewardsModule));
        uint256 couponPoolBalanceBefore = usdc.balanceOf(couponPool);

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(
            alice,
            address(0),
            SUBSCRIPTION,
            block.timestamp
        );

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);
        uint256 feeClaimAddressBalanceAfter = usdc.balanceOf(feeClaimAddress);
        uint256 contractBalanceAfter = usdc.balanceOf(address(subscriptionModule));
        uint256 referralCotractBalanceAfter = usdc.balanceOf(address(referralRewardsModule));
        uint256 couponPoolBalanceAfter = usdc.balanceOf(couponPool);

        assertEq(aliceBalanceAfter, aliceBalanceBefore);
        assertEq(
            feeClaimAddressBalanceAfter,
            feeClaimAddressBalanceBefore + ((SUBSCRIPTION * (FEE - REFERRAL_RESERVE)) / 100)
        );
        assertEq(
            contractBalanceAfter,
            contractBalanceBefore + SUBSCRIPTION - (SUBSCRIPTION * FEE) / 100
        );
        assertEq(
            referralCotractBalanceAfter,
            referralCotractBalanceBefore + (SUBSCRIPTION * REFERRAL_RESERVE) / 100
        );
        assertEq(couponPoolBalanceAfter, couponPoolBalanceBefore - SUBSCRIPTION);
    }

    function testSubscriptionModule_paySubscriptionOnBehalfOfEmitEventIfCouponsIsUsed() public {
        vm.prank(couponRedeemer);
        vm.expectEmit(true, true, false, false, address(subscriptionModule));
        emit OnCouponRedeemed(alice, SUBSCRIPTION);
        subscriptionModule.paySubscriptionOnBehalfOf(
            alice,
            address(0),
            SUBSCRIPTION,
            block.timestamp
        );
    }

    function testSubscriptionModule_donatesContribution() public payAndKyc {
        uint256 contractBalanceBefore = usdc.balanceOf(address(subscriptionModule));
        uint256 takasureReserveBalanceBefore = usdc.balanceOf(address(takasureReserve));

        vm.prank(takadao);
        subscriptionModule.transferSubscriptionToReserve(alice);

        uint256 contractBalanceAfter = usdc.balanceOf(address(subscriptionModule));
        uint256 takasureReserveBalanceAfter = usdc.balanceOf(address(takasureReserve));

        assertEq(contractBalanceBefore, SUBSCRIPTION - (SUBSCRIPTION * FEE) / 100);
        assertEq(takasureReserveBalanceBefore, 0);
        assertEq(contractBalanceAfter, 0);
        assertEq(contractBalanceBefore, takasureReserveBalanceAfter);
        assertEq(takasureReserveBalanceBefore, contractBalanceAfter);
    }
}
