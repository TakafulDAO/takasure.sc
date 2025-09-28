// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {DeployReserve} from "test/utils/02-DeployReserve.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {ReferralRewardsModule} from "contracts/modules/ReferralRewardsModule.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {BenefitModule} from "contracts/modules/BenefitModule.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {ModuleState, BenefitMember} from "contracts/types/TakasureTypes.sol";

contract Joins_BenefitTest is StdCheats, Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    DeployReserve reserveDeployer;
    AddAddressesAndRoles addressesAndRoles;

    KYCModule kycModule;
    MemberModule memberModule;
    SubscriptionModule subscriptionModule;
    ReferralRewardsModule referralRewardsModule;
    BenefitModule lifeModule;

    ModuleManager moduleManager;
    TakasureReserve takasureReserve;
    IUSDC usdc;

    address takadao;
    address couponRedeemer;
    address feeClaimAddress;
    address kycProvider;
    address couponPool;
    address public alice = makeAddr("alice");

    uint256 public constant USDC_INITIAL_AMOUNT = 275e6; // 275 USDC
    uint256 public constant YEAR = 365 days;
    uint256 public constant CONTRIBUTION_AMOUNT = 250e6; // 250 USDC

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        reserveDeployer = new DeployReserve();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addressManager,
            ModuleManager moduleMgr
        ) = managersDeployer.run();

        (
            address operator,
            ,
            address kyc,
            address redeemer,
            address feeClaimer,
            address pool,

        ) = addressesAndRoles.run(addressManager, config, address(moduleMgr));

        (
            lifeModule,
            ,
            kycModule,
            memberModule,
            referralRewardsModule,
            ,
            ,
            subscriptionModule
        ) = moduleDeployer.run(addressManager);

        takasureReserve = reserveDeployer.run(config, addressManager);

        takadao = operator;
        couponRedeemer = redeemer;
        feeClaimAddress = feeClaimer;
        kycProvider = kyc;
        couponPool = pool;
        moduleManager = moduleMgr;

        usdc = IUSDC(config.contributionToken);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(lifeModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

        vm.prank(kycProvider);
        kycModule.approveKYC(alice);
    }

    /// @dev Test that the paySubscription function updates the memberIdCounter
    function testBenefitModule_paySubscriptionUpdatesCounter() public {
        uint256 memberIdCounterBeforeAlice = takasureReserve.getReserveValues().memberIdCounter;

        vm.prank(couponRedeemer);
        lifeModule.joinBenefitOnBehalfOf(alice, CONTRIBUTION_AMOUNT, (5 * YEAR), 0);

        uint256 memberIdCounterAfterAlice = takasureReserve.getReserveValues().memberIdCounter;

        assertEq(memberIdCounterAfterAlice, memberIdCounterBeforeAlice + 1);
    }

    function testBenefitModule_paySubscriptionTransferAmountsCorrectly() public {
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(couponRedeemer);
        lifeModule.joinBenefitOnBehalfOf(alice, CONTRIBUTION_AMOUNT, (5 * YEAR), 0);

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);

        console2.log("Alice's balance before:", aliceBalanceBefore);
        console2.log("Alice's balance after:", aliceBalanceAfter);

        assert(aliceBalanceAfter < aliceBalanceBefore);
    }

    /// @dev Test the member is created
    function testBenefitModule_newMember() public {
        vm.prank(couponRedeemer);
        lifeModule.joinBenefitOnBehalfOf(alice, CONTRIBUTION_AMOUNT, (5 * YEAR), 0);

        uint256 memberId = takasureReserve.getReserveValues().memberIdCounter;

        // Check the member is created and added correctly to mappings
        BenefitMember memory testMember = takasureReserve.getMemberFromAddress(alice);

        assertEq(testMember.memberId, memberId);
        assertEq(testMember.contribution, CONTRIBUTION_AMOUNT);
        assertEq(testMember.wallet, alice);
        assertEq(uint8(testMember.memberState), 1);
    }
}
