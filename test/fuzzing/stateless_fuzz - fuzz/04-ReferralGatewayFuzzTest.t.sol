// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployReferralGateway} from "test/utils/00-DeployReferralGateway.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayFuzzTest is Test {
    DeployReferralGateway deployer;
    ReferralGateway referralGateway;
    IUSDC usdc;
    address takadao;
    address KYCProvider;
    address parent = makeAddr("parent");
    address child = makeAddr("child");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC

    event OnMemberJoined(uint256 indexed memberId, address indexed member);

    function setUp() public {
        // Deployer
        deployer = new DeployReferralGateway();
        HelperConfig.NetworkConfig memory config;
        (config, referralGateway) = deployer.run();

        // Get config values
        takadao = config.takadaoOperator;
        KYCProvider = config.kycProvider;

        // Assign implementations
        usdc = IUSDC(config.contributionToken);

        // Give and approve USDC
        deal(address(usdc), parent, USDC_INITIAL_AMOUNT);
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);

        vm.prank(parent);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        referralGateway.createDAO(true, true, 1743479999, 1e12);
        vm.stopPrank();

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            parent,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(parent);
    }

    // Fuzz to test to check the caller on pay contribution on behalf of
    function testPayContributionOnBehalfOfRevertsIfCallerIsWrong(address caller) public {
        vm.assume(caller != couponRedeemer);

        vm.prank(caller);
        vm.expectRevert();
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, false);
    }

    // Fuzz to test to check the caller refund if dao is not launched
    function testRefundIfDaoIsNotLaunchedRevertsIfCallerIsWrong(address caller) public {
        vm.assume(caller != child);
        vm.assume(caller != takadao);

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, address(0), child, 0, false);

        (, , , , , uint256 launchDate, , , , , , ) = referralGateway.getDAOData();

        vm.warp(launchDate);
        vm.roll(block.number + 1);

        vm.prank(caller);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotAuthorizedCaller.selector);
        referralGateway.refundIfDAOIsNotLaunched(child);
    }

    function testSwitchReferralDiscountRevertsIfCallerIsWrong(address caller) public {
        vm.assume(caller != takadao);

        vm.prank(caller);
        vm.expectRevert();
        referralGateway.switchReferralDiscount();
    }

    function testUpgradeRevertsIfCallerIsInvalid(address caller) public {
        vm.assume(caller != takadao);
        address newImpl = makeAddr("newImpl");

        vm.prank(caller);
        vm.expectRevert();
        referralGateway.upgradeToAndCall(newImpl, "");
    }
}
