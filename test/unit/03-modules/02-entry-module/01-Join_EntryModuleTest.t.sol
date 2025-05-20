// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Join_EntryModuleTest is StdCheats, Test, SimulateDonResponse {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    EntryModule entryModule;
    UserRouter userRouter;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address entryModuleAddress;
    address userRouterAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public parent = makeAddr("parent");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
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
            entryModuleAddress,
            ,
            ,
            userRouterAddress,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        entryModule = EntryModule(entryModuleAddress);
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
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(entryModuleAddress));

        vm.prank(takadao);
        entryModule.updateBmAddress();
    }

    /*//////////////////////////////////////////////////////////////
                                  JOIN
    //////////////////////////////////////////////////////////////*/

    /// @dev Test the contribution amount's last four digits are zero
    function testEntryModule_contributionAmountDecimals() public {
        uint256 contributionAmount = 227123456; // 227.123456 USDC

        deal(address(usdc), alice, contributionAmount);

        vm.startPrank(alice);

        usdc.approve(address(entryModule), contributionAmount);
        userRouter.joinPool(parent, contributionAmount, (5 * YEAR));

        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.approveKYC(alice);

        uint256 totalContributions = takasureReserve.getReserveValues().totalContributions;

        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assertEq(member.contribution, 227120000); // 227.120000 USDC
        assertEq(totalContributions, member.contribution);
    }

    /*//////////////////////////////////////////////////////////////
                      JOIN POOL::CREATE NEW MEMBER
    //////////////////////////////////////////////////////////////*/

    /// @dev Test that the joinPool function updates the memberIdCounter
    function testEntryModule_joinPoolUpdatesCounter() public {
        uint256 memberIdCounterBeforeAlice = takasureReserve.getReserveValues().memberIdCounter;

        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 memberIdCounterAfterAlice = takasureReserve.getReserveValues().memberIdCounter;

        vm.prank(bob);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 memberIdCounterAfterBob = takasureReserve.getReserveValues().memberIdCounter;

        assertEq(memberIdCounterAfterAlice, memberIdCounterBeforeAlice + 1);
        assertEq(memberIdCounterAfterBob, memberIdCounterAfterAlice + 1);
    }

    function testEntryModule_approveKYC() public {
        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assert(!member.isKYCVerified);

        vm.prank(admin);
        entryModule.approveKYC(alice);

        member = takasureReserve.getMemberFromAddress(alice);

        assert(member.isKYCVerified);
    }

    modifier aliceJoinAndKYC() {
        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.approveKYC(alice);

        _;
    }

    /// @dev Test the membership duration is 5 years if allowCustomDuration is false
    function testEntryModule_defaultMembershipDuration() public aliceJoinAndKYC {
        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assertEq(member.membershipDuration, 5 * YEAR);
    }

    /// @dev Test the membership custom duration
    function testEntryModule_customMembershipDuration() public {
        vm.prank(admin);
        takasureReserve.setAllowCustomDuration(true);

        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, YEAR);

        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assertEq(member.membershipDuration, YEAR);
    }

    /// @dev Test the member is created
    function testEntryModule_newMember() public {
        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

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
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.approveKYC(bob);
        _;
    }

    /// @dev More than one can join
    function testEntryModule_moreThanOneJoin() public aliceJoinAndKYC bobJoinAndKYC {
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
    function testEntryModule_proFormasUpdatedOnMemberJoined() public aliceJoinAndKYC {
        vm.prank(bob);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        Reserve memory reserve = takasureReserve.getReserveValues();

        uint256 initialProFormaFundReserve = reserve.proFormaFundReserve;
        uint256 initialProFormaClaimReserve = reserve.proFormaClaimReserve;

        vm.prank(admin);
        entryModule.approveKYC(bob);

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
    function testEntryModule_drrCalculatedOnMemberJoined() public {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint256 currentDRR = reserve.dynamicReserveRatio;
        uint256 initialDRR = reserve.initialReserveRatio;

        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.approveKYC(alice);

        reserve = takasureReserve.getReserveValues();
        uint256 aliceDRR = reserve.dynamicReserveRatio;

        vm.prank(bob);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.approveKYC(bob);

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
    function testEntryModule_bmaCalculatedOnMemberJoined() public {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint256 initialBMA = reserve.benefitMultiplierAdjuster;

        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.approveKYC(alice);

        reserve = takasureReserve.getReserveValues();
        uint256 aliceBMA = reserve.benefitMultiplierAdjuster;

        vm.prank(bob);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.approveKYC(bob);

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
                        JOINPOOL::TOKENS MINTED
    //////////////////////////////////////////////////////////////*/
    /// @dev Test the tokens minted are staked in the pool
    function testEntryModule_tokensMinted() public {
        Reserve memory reserve = takasureReserve.getReserveValues();
        address creditToken = reserve.daoToken;
        TSToken creditTokenInstance = TSToken(creditToken);

        uint256 contractCreditTokenBalanceBefore = creditTokenInstance.balanceOf(
            address(takasureReserve)
        );
        uint256 aliceCreditTokenBalanceBefore = creditTokenInstance.balanceOf(alice);

        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.approveKYC(alice);

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

    function testGasBenchMark_joinPoolThroughUserRouter() public {
        // Gas used: 505546
        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));
    }

    function testGasBenchMark_joinPoolThroughEntryModule() public {
        // Gas used: 495580
        vm.prank(alice);
        entryModule.joinPool(alice, parent, CONTRIBUTION_AMOUNT, (5 * YEAR));
    }
}
