// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployReferralGateway} from "test/utils/00-DeployReferralGateway.s.sol";
import {DeployReserve} from "test/utils/02-DeployReserve.s.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {DaoDataReader, IReferralGateway} from "test/helpers/lowLevelCall/DaoDataReader.sol";

contract ReferralGatewayRepoolTest is Test {
    DeployReferralGateway deployer;
    DeployReserve takasureDeployer;
    DeployManagers managersDeployer;
    ReferralGateway referralGateway;
    TakasureReserve takasureReserve;
    IUSDC usdc;
    address takadao;
    address KYCProvider;
    address child = makeAddr("child");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC

    function setUp() public {
        // Deployer
        deployer = new DeployReferralGateway();
        HelperConfig.NetworkConfig memory config;
        (config, referralGateway) = deployer.run();

        managersDeployer = new DeployManagers();
        (, AddressManager addressManager, ) = managersDeployer.run();

        takasureDeployer = new DeployReserve();
        takasureReserve = takasureDeployer.run(config, addressManager);

        // Get config values
        takadao = config.takadaoOperator;
        KYCProvider = config.kycProvider;

        // Assign implementations
        usdc = IUSDC(config.contributionToken);

        // Give and approve USDC
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);

        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        referralGateway.createDAO(true, true, 1743479999, 1e12);
        vm.stopPrank();
    }

    function testTransferToRepool() public {
        address parentTier1 = makeAddr("parentTier1");
        address parentTier2 = makeAddr("parentTier2");
        address parentTier3 = makeAddr("parentTier3");
        address parentTier4 = makeAddr("parentTier4");
        address[4] memory parents = [parentTier1, parentTier2, parentTier3, parentTier4];

        for (uint256 i = 0; i < parents.length; i++) {
            deal(address(usdc), parents[i], 10 * CONTRIBUTION_AMOUNT);
            vm.startPrank(parents[i]);
            usdc.approve(address(referralGateway), 10 * CONTRIBUTION_AMOUNT);
            vm.stopPrank();
        }

        address childWithoutReferee = makeAddr("childWithoutReferee");
        deal(address(usdc), childWithoutReferee, 10 * CONTRIBUTION_AMOUNT);
        vm.prank(childWithoutReferee);
        usdc.approve(address(referralGateway), 10 * CONTRIBUTION_AMOUNT);

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            parentTier1,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier1);

        uint256 parentTier2Contribution = 5 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier2Contribution,
            parentTier1,
            parentTier2,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier2);

        uint256 parentTier3Contribution = 2 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier3Contribution,
            parentTier2,
            parentTier3,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier3);

        uint256 parentTier4Contribution = 7 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            parentTier4Contribution,
            parentTier3,
            parentTier4,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(parentTier4);

        uint256 childWithoutRefereeContribution = 4 * CONTRIBUTION_AMOUNT;
        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            childWithoutRefereeContribution,
            parentTier4,
            childWithoutReferee,
            0,
            false
        );

        vm.prank(KYCProvider);
        referralGateway.approveKYC(childWithoutReferee);

        address subscriptionModule = makeAddr("subscriptionModule");

        vm.prank(takadao);
        referralGateway.launchDAO(address(takasureReserve), subscriptionModule, true);

        address rePoolAddress = makeAddr("rePoolAddress");

        vm.prank(takadao);
        referralGateway.enableRepool(rePoolAddress);

        uint256 toRepool = DaoDataReader.getUint(IReferralGateway(address(referralGateway)), 10);

        assert(toRepool > 0);
        assertEq(usdc.balanceOf(rePoolAddress), 0);

        vm.prank(takadao);
        referralGateway.transferToRepool();

        uint256 newRepoolBalance = DaoDataReader.getUint(
            IReferralGateway(address(referralGateway)),
            10
        );

        assertEq(newRepoolBalance, 0);
        assertEq(usdc.balanceOf(rePoolAddress), toRepool);
    }
}
