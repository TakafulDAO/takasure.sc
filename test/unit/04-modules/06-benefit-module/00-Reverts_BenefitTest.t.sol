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
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {ReferralRewardsModule} from "contracts/modules/ReferralRewardsModule.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {BenefitModule} from "contracts/modules/BenefitModule.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";

contract Reverts_BenefitTest is StdCheats, Test {
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

    uint256 public constant USDC_INITIAL_AMOUNT = 1000e6; // 1000 USDC
    uint256 public constant YEAR = 365 days;

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
            address pool
        ) = addressesAndRoles.run(addressManager, config, address(moduleMgr));

        (
            lifeModule,
            ,
            kycModule,
            memberModule,
            referralRewardsModule,
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

        vm.prank(alice);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
    }

    function testBenefitModule_joinBenefitRevertsIfCouponIsInvalid() public {
        vm.prank(couponRedeemer);
        vm.expectRevert(ModuleErrors.Module__InvalidCoupon.selector);
        lifeModule.joinBenefitOnBehalfOf(alice, 50e6, 5 * YEAR, 100e6);
    }

    function testBenefitModule_joinBenefitRevertsIfAddressIsNotKYCed() public {
        vm.prank(couponRedeemer);
        vm.expectRevert(ModuleErrors.Module__AddressNotKYCed.selector);
        lifeModule.joinBenefitOnBehalfOf(alice, 50e6, 5 * YEAR, 0);
    }

    function testBenefitModule_joinBenefitRevertsIfModuleDisabled() public {
        vm.prank(address(moduleManager));
        lifeModule.setContractState(ModuleState.Paused);

        vm.prank(couponRedeemer);
        vm.expectRevert();
        lifeModule.joinBenefitOnBehalfOf(alice, 50e6, 5 * YEAR, 0);
    }
}
