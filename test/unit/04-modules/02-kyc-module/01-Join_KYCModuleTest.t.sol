// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, Reserve, ProtocolAddress} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract Join_SubscriptionModuleTest is StdCheats, Test {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
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
    uint256 public constant BM = 1;

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            ,
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

        vm.prank(admin);
        kycModule.approveKYC(alice, BM);

        uint256 totalContributions = takasureReserve.getReserveValues().totalContributions;

        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assertEq(member.contribution, 227120000); // 227.120000 USDC
        assertEq(totalContributions, member.contribution);
    }

    /*//////////////////////////////////////////////////////////////
                      JOIN POOL::CREATE NEW MEMBER
    //////////////////////////////////////////////////////////////*/

    /// @dev Test that the paySubscription function updates the memberIdCounter
    function testSubscriptionModule_paySubscriptionUpdatesCounter() public {
        uint256 memberIdCounterBeforeAlice = takasureReserve.getReserveValues().memberIdCounter;

        vm.prank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 memberIdCounterAfterAlice = takasureReserve.getReserveValues().memberIdCounter;

        vm.prank(bob);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 memberIdCounterAfterBob = takasureReserve.getReserveValues().memberIdCounter;

        assertEq(memberIdCounterAfterAlice, memberIdCounterBeforeAlice + 1);
        assertEq(memberIdCounterAfterBob, memberIdCounterAfterAlice + 1);
    }

    function testSubscriptionModule_paySubscriptionTransferAmountsCorrectly() public {
        uint256 aliceBalanceBefore = usdc.balanceOf(alice);

        vm.prank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 aliceBalanceAfter = usdc.balanceOf(alice);

        assertEq(aliceBalanceAfter, aliceBalanceBefore - CONTRIBUTION_AMOUNT);
    }

    function testSubscriptionModule_approveKYC() public {
        vm.prank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assert(!member.isKYCVerified);

        vm.prank(admin);
        kycModule.approveKYC(alice, BM);

        member = takasureReserve.getMemberFromAddress(alice);

        assert(member.isKYCVerified);
    }

    modifier aliceJoinAndKYC() {
        vm.prank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        vm.prank(admin);
        kycModule.approveKYC(alice, BM);

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

        address addressManager = address(takasureReserve.addressManager());

        vm.startPrank(AddressManager(addressManager).owner());
        AddressManager(addressManager).createNewRole(keccak256("COUPON_REDEEMER"));
        AddressManager(addressManager).proposeRoleHolder(
            keccak256("COUPON_REDEEMER"),
            couponRedeemer
        );
        vm.stopPrank();

        vm.prank(couponRedeemer);
        AddressManager(addressManager).acceptProposedRole(keccak256("COUPON_REDEEMER"));

        vm.prank(takadao);
        subscriptionModule.setCouponPoolAddress(couponPool);

        deal(address(usdc), couponPool, coupon);

        vm.prank(couponPool);
        usdc.approve(address(subscriptionModule), coupon);

        uint256 subscriptionModuleBalanceBefore = usdc.balanceOf(address(subscriptionModule));
        uint256 bobBalanceBefore = usdc.balanceOf(bob);
        uint256 couponPoolBalanceBefore = usdc.balanceOf(couponPool);
        uint256 feeClaimAddressBalanceBefore = usdc.balanceOf(
            AddressManager(addressManager).getProtocolAddressByName("FEE_CLAIM_ADDRESS").addr
        );

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(bob, alice, contribution, (5 * YEAR), coupon);

        uint256 subscriptionModuleBalanceAfter = usdc.balanceOf(address(subscriptionModule));
        // uint256 bobBalanceAfter = usdc.balanceOf(bob);
        // uint256 couponPoolBalanceAfter = usdc.balanceOf(couponPool);
        uint256 feeClaimAddressBalanceAfter = usdc.balanceOf(
            AddressManager(addressManager).getProtocolAddressByName("FEE_CLAIM_ADDRESS").addr
        );
        uint256 expectedTransferAmount = (contribution - coupon) -
            (((contribution - coupon) * 5) / 100); // (250 - 50) - ((250 - 50) * 5%) = 200 - 10 = 190 USDC

        // SubscriptionModule balance should be 0 from the beginning, because Alice has already joined
        // and KYCed, this means the subscription module transfers the contribution amount to the takasureReserve
        assertEq(subscriptionModuleBalanceBefore, 0);
        // After Bob joins, the subscription module balance should be 172.5 USDC, this is contribution - fee - discounts
        // 250 - (250 * 27%) - ((contribution - coupon) * 5%) = 250 - 67.5 - ((250 - 50) * 5%) = 182.5 - 10 = 172.5 USDC
        assertEq(subscriptionModuleBalanceAfter, 1725e5); // 172.5 USDC
        // The coupon balance should be the initial coupon balance minus the coupon used
        assertEq(usdc.balanceOf(couponPool), couponPoolBalanceBefore - coupon);
        // Bob's balance should be => initial balance - (contribution - coupon) + discount
        // 1000 - (250 - 50) + 10 = 1000 - 200 + 10 = 810 USDC
        assertEq(usdc.balanceOf(bob), bobBalanceBefore - expectedTransferAmount);
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

    /// @dev Test the membership custom duration
    function testSubscriptionModule_customMembershipDuration() public {
        vm.prank(admin);
        takasureReserve.setAllowCustomDuration(true);

        vm.prank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, YEAR);

        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assertEq(member.membershipDuration, YEAR);
    }

    /// @dev Test the member is created
    function testSubscriptionModule_newMember() public {
        vm.prank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 memberId = takasureReserve.getReserveValues().memberIdCounter;

        // Check the member is created and added correctly to mappings
        Member memory testMember = takasureReserve.getMemberFromAddress(alice);

        assertEq(testMember.memberId, memberId);
        assertEq(testMember.benefitMultiplier, BENEFIT_MULTIPLIER);
        assertEq(testMember.contribution, CONTRIBUTION_AMOUNT);
        assertEq(testMember.wallet, alice);
        assertEq(uint8(testMember.memberState), 0);
    }

    modifier bobJoinAndKYC() {
        vm.prank(bob);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        vm.prank(admin);
        kycModule.approveKYC(bob, BM);
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
        kycModule.approveKYC(bob, BM);

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

        vm.prank(admin);
        kycModule.approveKYC(alice, BM);

        reserve = takasureReserve.getReserveValues();
        uint256 aliceDRR = reserve.dynamicReserveRatio;

        vm.prank(bob);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        vm.prank(admin);
        kycModule.approveKYC(bob, BM);

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

        vm.prank(admin);
        kycModule.approveKYC(alice, BM);

        reserve = takasureReserve.getReserveValues();
        uint256 aliceBMA = reserve.benefitMultiplierAdjuster;

        vm.prank(bob);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));

        vm.prank(admin);
        kycModule.approveKYC(bob, BM);

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

        vm.prank(admin);
        kycModule.approveKYC(alice, BM);

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

    function testGasBenchMark_paySubscriptionThroughUserRouter() public {
        // Gas used: 505546
        vm.prank(alice);
        userRouter.paySubscription(address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));
    }

    function testGasBenchMark_paySubscriptionThroughSubscriptionModule() public {
        // Gas used: 495580
        vm.prank(alice);
        subscriptionModule.paySubscription(alice, address(0), CONTRIBUTION_AMOUNT, (5 * YEAR));
    }
}
