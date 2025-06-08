// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract ReferralGatewayJoinDaoTest is Test, SimulateDonResponse {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    TakasureReserve takasureReserve;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takasureReserveAddress;
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
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (
            ,
            bmConsumerMock,
            takasureReserveAddress,
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

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
        takasureReserve = TakasureReserve(takasureReserveAddress);
        usdc = IUSDC(usdcAddress);

        // Config mocks
        vm.prank(takadao);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(takasureReserve));
        bmConsumerMock.setNewRequester(referralGatewayAddress);

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
        referralGateway.createDAO(true, true, 1743479999, 1e12, address(bmConsumerMock));
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

        vm.prank(takadao);
        referralGateway.launchDAO(address(takasureReserve), true);

        vm.prank(child);
        vm.expectRevert(ReferralGateway.ReferralGateway__NotKYCed.selector);
        emit OnMemberJoined(2, child);
        referralGateway.joinDAO(child);
    }
}
