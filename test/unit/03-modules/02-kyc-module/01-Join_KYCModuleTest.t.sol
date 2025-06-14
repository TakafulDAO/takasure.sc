// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Join_SubscriptionModuleTest is StdCheats, Test, SimulateDonResponse {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    SubscriptionModule subscriptionModule;
    KYCModule kycModule;
    UserRouter userRouter;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address subscriptionModuleAddress;
    address kycModuleAddress;
    address userRouterAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    uint256 public constant USDC_INITIAL_AMOUNT = 1000e6; // 1000 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            ,
            bmConsumerMock,
            takasureReserveProxy,
            ,
            subscriptionModuleAddress,
            kycModuleAddress,
            ,
            ,
            userRouterAddress,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        subscriptionModule = SubscriptionModule(subscriptionModuleAddress);
        kycModule = KYCModule(kycModuleAddress);
        userRouter = UserRouter(userRouterAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
        deal(address(usdc), bob, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.startPrank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(subscriptionModuleAddress);
        bmConsumerMock.setNewRequester(kycModuleAddress);
        vm.stopPrank();

        vm.startPrank(takadao);
        subscriptionModule.updateBmAddress();
        kycModule.updateBmAddress();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                  JOIN
    //////////////////////////////////////////////////////////////*/

    /// @dev Test the contribution amount's last four digits are zero
    function testSubscriptionModule_contributionAmountDecimals() public {
        uint256 contributionAmount = 227123456; // 227.123456 USDC

        deal(address(usdc), alice, contributionAmount);

        vm.startPrank(alice);

        usdc.approve(address(subscriptionModule), contributionAmount);
        userRouter.paySubscription(address(0), contributionAmount, (5 * YEAR));

        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        kycModule.approveKYC(alice);

        uint256 totalContributions = takasureReserve.getReserveValues().totalContributions;

        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assertEq(member.contribution, 227120000); // 227.120000 USDC
        assertEq(totalContributions, member.contribution);
    }

    /*//////////////////////////////////////////////////////////////
                      JOIN POOL::CREATE NEW MEMBER
    //////////////////////////////////////////////////////////////*/

    function testSubscriptionModule_approveKYC() public {
        vm.prank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assert(!member.isKYCVerified);

        vm.prank(admin);
        kycModule.approveKYC(alice);

        member = takasureReserve.getMemberFromAddress(alice);

        assert(member.isKYCVerified);
    }

    modifier aliceJoinAndKYC() {
        vm.prank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        kycModule.approveKYC(alice);

        _;
    }

    function testSubscriptionModule_paySubscriptionOnBehalfOfTransferAmountsCorrectly()
        public
        aliceJoinAndKYC
    {
        address couponRedeemer = makeAddr("couponRedeemer");
        address couponPool = makeAddr("couponPool");

        uint256 contribution = 250e6; // 250 USDC
        uint256 coupon = 50e6; // 50 USDC

        vm.startPrank(takadao);
        subscriptionModule.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        subscriptionModule.setCouponPoolAddress(couponPool);
        vm.stopPrank();

        deal(address(usdc), couponPool, coupon);

        vm.prank(couponPool);
        usdc.approve(address(subscriptionModule), coupon);

        uint256 subscriptionModuleBalanceBefore = usdc.balanceOf(address(subscriptionModule));
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        uint256 couponPoolBalanceBefore = usdc.balanceOf(couponPool);
        uint256 feeClaimAddressBalanceBefore = usdc.balanceOf(takasureReserve.feeClaimAddress());

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(bob, alice, contribution, (5 * YEAR), coupon);

        uint256 subscriptionModuleBalanceAfter = usdc.balanceOf(address(subscriptionModule));
        uint256 bobBalanceAfter = usdc.balanceOf(bob);
        uint256 couponPoolBalanceAfter = usdc.balanceOf(couponPool);
        uint256 feeClaimAddressBalanceAfter = usdc.balanceOf(takasureReserve.feeClaimAddress());
        uint256 expectedTransferAmount = (contribution - coupon) -
            (((contribution - coupon) * 5) / 100); // (250 - 50) - ((250 - 50) * 5%) = 200 - 10 = 190 USDC

        // SubscriptionModule balance should be 0 from the beginning, because Alice has already joined
        // and KYCed, this means the subscription module transfers the contribution amount to the takasureReserve
        assertEq(subscriptionModuleBalanceBefore, 0);
        // After Bob joins, the subscription module balance should be 172.5 USDC, this is contribution - fee - discounts
        // 250 - (250 * 27%) - ((contribution - coupon) * 5%) = 250 - 67.5 - ((250 - 50) * 5%) = 182.5 - 10 = 172.5 USDC
        assertEq(subscriptionModuleBalanceAfter, 1725e5); // 172.5 USDC
        // The coupon balance should be the initial coupon balance minus the coupon used
        assertEq(couponPoolBalanceAfter, couponPoolBalanceBefore - coupon);
        // Bob's balance should be => initial balance - (contribution - coupon) + discount
        // 1000 - (250 - 50) + 10 = 1000 - 200 + 10 = 810 USDC
        assertEq(bobBalanceAfter, bobBalanceBefore - expectedTransferAmount);
        assertEq(expectedTransferAmount, 190e6); // 190 USDC
        // The feeClaimAddress balance should be increased by the fee
        // 250 * 27% = 67.5
        assertEq(
            feeClaimAddressBalanceAfter - feeClaimAddressBalanceBefore,
            (contribution * 27) / 100
        );
        // The subscription module balance plus the discount plus the fee should be equal to the contribution amount
        assertEq(
            subscriptionModuleBalanceAfter +
                (((contribution - coupon) * 5) / 100) +
                feeClaimAddressBalanceAfter -
                feeClaimAddressBalanceBefore,
            contribution
        );
    }

    /// @dev Test the membership duration is 5 years if allowCustomDuration is false
    function testSubscriptionModule_defaultMembershipDuration() public aliceJoinAndKYC {
        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assertEq(member.membershipDuration, 5 * YEAR);
    }

    modifier bobJoinAndKYC() {
        vm.prank(bob);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        kycModule.approveKYC(bob);
        _;
    }

    /// @dev More than one can join
    function testSubscriptionModule_moreThanOneJoin() public aliceJoinAndKYC bobJoinAndKYC {
        Member memory aliceMember = takasureReserve.getMemberFromAddress(alice);
        Member memory bobMember = takasureReserve.getMemberFromAddress(bob);

        uint256 totalContributions = takasureReserve.getReserveValues().totalContributions;

        assertEq(aliceMember.wallet, alice);
        assertEq(bobMember.wallet, bob);
        assert(aliceMember.memberId != bobMember.memberId);

        assertEq(totalContributions, 2 * CONTRIBUTION_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                    JOIN POOL::UPDATE BOTH PRO FORMAS
    //////////////////////////////////////////////////////////////*/
    /// @dev Pro formas updated when a member joins
    function testSubscriptionModule_proFormasUpdatedOnMemberJoined() public aliceJoinAndKYC {
        vm.prank(bob);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        Reserve memory reserve = takasureReserve.getReserveValues();

        uint256 initialProFormaFundReserve = reserve.proFormaFundReserve;
        uint256 initialProFormaClaimReserve = reserve.proFormaClaimReserve;

        vm.prank(admin);
        kycModule.approveKYC(bob);

        reserve = takasureReserve.getReserveValues();

        uint256 finalProFormaFundReserve = reserve.proFormaFundReserve;
        uint256 finalProFormaClaimReserve = reserve.proFormaClaimReserve;

        assert(finalProFormaFundReserve > initialProFormaFundReserve);
        assert(finalProFormaClaimReserve > initialProFormaClaimReserve);
    }

    /*//////////////////////////////////////////////////////////////
                         JOIN POOL::UPDATE DRR
    //////////////////////////////////////////////////////////////*/
    /// @dev New DRR is calculated when a member joins
    function testSubscriptionModule_drrCalculatedOnMemberJoined() public {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint256 currentDRR = reserve.dynamicReserveRatio;
        uint256 initialDRR = reserve.initialReserveRatio;

        vm.prank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        kycModule.approveKYC(alice);

        reserve = takasureReserve.getReserveValues();
        uint256 aliceDRR = reserve.dynamicReserveRatio;

        vm.prank(bob);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        kycModule.approveKYC(bob);

        reserve = takasureReserve.getReserveValues();
        uint256 bobDRR = reserve.dynamicReserveRatio;

        uint256 expectedAliceDRR = 48;
        uint256 expectedBobDRR = 44;

        assertEq(currentDRR, initialDRR);
        assertEq(aliceDRR, expectedAliceDRR);
        assertEq(bobDRR, expectedBobDRR);
    }

    /*//////////////////////////////////////////////////////////////
                         JOIN POOL::UPDATE BMA
    //////////////////////////////////////////////////////////////*/
    /// @dev New BMA is calculated when a member joins
    function testSubscriptionModule_bmaCalculatedOnMemberJoined() public {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint256 initialBMA = reserve.benefitMultiplierAdjuster;

        vm.prank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        kycModule.approveKYC(alice);

        reserve = takasureReserve.getReserveValues();
        uint256 aliceBMA = reserve.benefitMultiplierAdjuster;

        vm.prank(bob);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        kycModule.approveKYC(bob);

        reserve = takasureReserve.getReserveValues();
        uint256 bobBMA = reserve.benefitMultiplierAdjuster;

        uint256 expectedInitialBMA = 100;
        uint256 expectedAliceBMA = 88;
        uint256 expectedBobBMA = 86;

        assertEq(initialBMA, expectedInitialBMA);
        assertEq(aliceBMA, expectedAliceBMA);
        assertEq(bobBMA, expectedBobBMA);
    }

    /*//////////////////////////////////////////////////////////////
                        paySubscription::TOKENS MINTED
    //////////////////////////////////////////////////////////////*/
    /// @dev Test the tokens minted are staked in the pool
    function testSubscriptionModule_tokensMinted() public {
        Reserve memory reserve = takasureReserve.getReserveValues();
        address creditToken = reserve.daoToken;
        TSToken creditTokenInstance = TSToken(creditToken);

        uint256 contractCreditTokenBalanceBefore = creditTokenInstance.balanceOf(
            address(takasureReserve)
        );
        uint256 aliceCreditTokenBalanceBefore = creditTokenInstance.balanceOf(alice);

        vm.prank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        kycModule.approveKYC(alice);

        uint256 contractCreditTokenBalanceAfter = creditTokenInstance.balanceOf(
            address(takasureReserve)
        );
        uint256 aliceCreditTokenBalanceAfter = creditTokenInstance.balanceOf(alice);

        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assertEq(contractCreditTokenBalanceBefore, 0);
        assertEq(aliceCreditTokenBalanceBefore, 0);

        assertEq(contractCreditTokenBalanceAfter, CONTRIBUTION_AMOUNT * 10 ** 12);
        assertEq(aliceCreditTokenBalanceAfter, 0);

        assertEq(member.creditTokensBalance, contractCreditTokenBalanceAfter);
    }
}
