// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployReferralGateway} from "test/utils/00-DeployReferralGateway.s.sol";
import {DeployTakasureReserve} from "test/utils/02-DeployTakasureReserve.s.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayJoinDaoTest is Test {
    DeployReferralGateway deployer;
    DeployTakasureReserve takasureDeployer;
    DeployManagers managersDeployer;
    ReferralGateway referralGateway;
    TakasureReserve takasureReserve;
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

        managersDeployer = new DeployManagers();
        (, AddressManager addressManager, , , , , , ) = managersDeployer.run();

        takasureDeployer = new DeployTakasureReserve();
        takasureReserve = takasureDeployer.run(config, addressManager);

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
        referralGateway.setDaoName(tDaoName);
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

    function testMustRevertJoinPoolIfTheDaoHasNoAssignedAddressYet() public {
        vm.prank(parent);
        vm.expectRevert(ReferralGateway.ReferralGateway__tDAONotReadyYet.selector);
        emit OnMemberJoined(2, parent);
        referralGateway.joinDAO(parent);
    }

    function testMustRevertJoinPoolIfTheChildIsNotKYC() public {
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(CONTRIBUTION_AMOUNT, parent, child, 0, false);

        address subscriptionModule = makeAddr("subscriptionModule");

        vm.prank(takadao);
        referralGateway.launchDAO(address(takasureReserve), subscriptionModule, true);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotKYCed.selector);
        emit OnMemberJoined(2, child);
        referralGateway.joinDAO(child);
    }
}
