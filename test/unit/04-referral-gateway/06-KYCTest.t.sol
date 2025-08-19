// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayKYCTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takadao;
    address KYCProvider;
    address pauseGuardian;
    address addressToKyc = makeAddr("addressToKyc");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC

    modifier pauseContract() {
        vm.prank(pauseGuardian);
        referralGateway.pause();
        _;
    }

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (
            ,
            bmConsumerMock,
            ,
            referralGatewayAddress,
            ,
            ,
            ,
            ,
            ,
            usdcAddress,
            ,
            helperConfig
        ) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        KYCProvider = config.kycProvider;
        pauseGuardian = config.pauseGuardian;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
        usdc = IUSDC(usdcAddress);

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(referralGatewayAddress);

        // Give and approve USDC
        deal(address(usdc), addressToKyc, USDC_INITIAL_AMOUNT);

        vm.prank(addressToKyc);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        referralGateway.createDAO(true, true, 1743479999, 1e12);
        vm.stopPrank();

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            addressToKyc,
            0,
            false
        );
    }

    function testKYCAnAddress() public {
        vm.prank(KYCProvider);
        vm.expectRevert(ReferralGateway.ReferralGateway__ZeroAddress.selector);
        referralGateway.approveKYC(address(0));

        assert(!referralGateway.isMemberKYCed(addressToKyc));

        vm.prank(KYCProvider);
        referralGateway.approveKYC(addressToKyc);
        assert(referralGateway.isMemberKYCed(addressToKyc));
    }

    function testKYCRevertIfContractPaused() public pauseContract {
        vm.prank(KYCProvider);
        vm.expectRevert();
        referralGateway.approveKYC(addressToKyc);
    }

    function testMustRevertIfKYCTwiceSameAddress() public {
        vm.startPrank(KYCProvider);
        referralGateway.approveKYC(addressToKyc);

        vm.expectRevert(ReferralGateway.ReferralGateway__MemberAlreadyKYCed.selector);
        referralGateway.approveKYC(addressToKyc);
        vm.stopPrank();
    }
}
