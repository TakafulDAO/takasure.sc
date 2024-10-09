// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {DeployConsumerMocks} from "test/utils/DeployConsumerMocks.s.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {JoinModule} from "contracts/takasure/modules/JoinModule.sol";
import {TSTokenSize} from "contracts/token/TSTokenSize.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, NewReserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Join_TakasureProtocolTest is StdCheats, Test, SimulateDonResponse {
    TestDeployTakasureReserve deployer;
    DeployConsumerMocks mockDeployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    JoinModule joinModule;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address joinModuleAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployTakasureReserve();
        (
            takasureReserveProxy,
            joinModuleAddress,
            ,
            ,
            contributionTokenAddress,
            helperConfig
        ) = deployer.run();

        joinModule = JoinModule(joinModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        mockDeployer = new DeployConsumerMocks();
        bmConsumerMock = mockDeployer.run();

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
        deal(address(usdc), bob, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(joinModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(joinModuleAddress));

        vm.prank(takadao);
        joinModule.updateBmAddress();
    }

    /*//////////////////////////////////////////////////////////////
                                  JOIN
    //////////////////////////////////////////////////////////////*/

    /// @dev Test the contribution amount's last four digits are zero
    function testJoinModule_contributionAmountDecimals() public {
        uint256 contributionAmount = 227123456; // 227.123456 USDC

        deal(address(usdc), alice, contributionAmount);

        vm.startPrank(alice);

        usdc.approve(address(joinModule), contributionAmount);
        joinModule.joinPool(contributionAmount, (5 * YEAR));

        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        joinModule.setKYCStatus(alice);

        uint256 totalContributions = takasureReserve.getReserveValues().totalContributions;

        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assertEq(member.contribution, 227120000); // 227.120000 USDC
        assertEq(totalContributions, member.contribution);
    }

    /*//////////////////////////////////////////////////////////////
                      JOIN POOL::CREATE NEW MEMBER
    //////////////////////////////////////////////////////////////*/

    /// @dev Test that the joinPool function updates the memberIdCounter
    function testJoinModule_joinPoolUpdatesCounter() public {
        uint256 memberIdCounterBeforeAlice = takasureReserve.getReserveValues().memberIdCounter;

        vm.prank(alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 memberIdCounterAfterAlice = takasureReserve.getReserveValues().memberIdCounter;

        vm.prank(bob);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 memberIdCounterAfterBob = takasureReserve.getReserveValues().memberIdCounter;

        assertEq(memberIdCounterAfterAlice, memberIdCounterBeforeAlice + 1);
        assertEq(memberIdCounterAfterBob, memberIdCounterAfterAlice + 1);
    }

    modifier aliceKYCAndJoin() {
        vm.prank(admin);
        joinModule.setKYCStatus(alice);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        _;
    }

    /// @dev Test the membership duration is 5 years if allowCustomDuration is false
    function testTakasureReserve_defaultMembershipDuration() public aliceKYCAndJoin {
        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assertEq(member.membershipDuration, 5 * YEAR);
    }

    /// @dev Test the membership custom duration
    function testJoinModule_customMembershipDuration() public {
        vm.prank(admin);
        takasureReserve.setAllowCustomDuration(true);

        vm.prank(alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, YEAR);

        Member memory member = takasureReserve.getMemberFromAddress(alice);

        assertEq(member.membershipDuration, YEAR);
    }

    /// @dev Test the member is created
    function testTakasureReserve_newMember() public {
        vm.prank(alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 memberId = takasureReserve.getReserveValues().memberIdCounter;

        // Check the member is created and added correctly to mappings
        Member memory testMember = takasureReserve.getMemberFromAddress(alice);

        assertEq(testMember.memberId, memberId);
        assertEq(testMember.benefitMultiplier, BENEFIT_MULTIPLIER);
        assertEq(testMember.contribution, CONTRIBUTION_AMOUNT);
        assertEq(testMember.wallet, alice);
        assertEq(uint8(testMember.memberState), 0);
    }

    modifier bobKYCAndJoin() {
        vm.prank(admin);
        joinModule.setKYCStatus(bob);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(bob);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));
        _;
    }

    /// @dev More than one can join
    function testTakasureReserve_moreThanOneJoin() public aliceKYCAndJoin bobKYCAndJoin {
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
    function testTakasureReserve_proFormasUpdatedOnMemberJoined() public aliceKYCAndJoin {
        vm.prank(admin);
        joinModule.setKYCStatus(bob);

        NewReserve memory reserve = takasureReserve.getReserveValues();

        uint256 initialProFormaFundReserve = reserve.proFormaFundReserve;
        uint256 initialProFormaClaimReserve = reserve.proFormaClaimReserve;

        vm.prank(bob);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

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
    function testTakasureReserve_drrCalculatedOnMemberJoined() public {
        NewReserve memory reserve = takasureReserve.getReserveValues();
        uint256 currentDRR = reserve.dynamicReserveRatio;
        uint256 initialDRR = reserve.initialReserveRatio;

        vm.startPrank(admin);

        joinModule.setKYCStatus(alice);
        joinModule.setKYCStatus(bob);

        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        reserve = takasureReserve.getReserveValues();
        uint256 aliceDRR = reserve.dynamicReserveRatio;

        vm.prank(bob);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

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
    function testTakasureReserve_bmaCalculatedOnMemberJoined() public {
        NewReserve memory reserve = takasureReserve.getReserveValues();
        uint256 initialBMA = reserve.benefitMultiplierAdjuster;

        vm.startPrank(admin);

        joinModule.setKYCStatus(alice);
        joinModule.setKYCStatus(bob);

        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        reserve = takasureReserve.getReserveValues();
        uint256 aliceBMA = reserve.benefitMultiplierAdjuster;

        vm.prank(bob);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        reserve = takasureReserve.getReserveValues();
        uint256 bobBMA = reserve.benefitMultiplierAdjuster;

        uint256 expectedInitialBMA = 100;
        uint256 expectedAliceBMA = 90;
        uint256 expectedBobBMA = 88;

        assertEq(initialBMA, expectedInitialBMA);
        assertEq(aliceBMA, expectedAliceBMA);
        assertEq(bobBMA, expectedBobBMA);
    }

    /*//////////////////////////////////////////////////////////////
                        JOINPOOL::TOKENS MINTED
    //////////////////////////////////////////////////////////////*/
    /// @dev Test the tokens minted are staked in the pool
    function testTakasureReserve_tokensMinted() public {
        NewReserve memory reserve = takasureReserve.getReserveValues();
        address creditToken = reserve.daoToken;
        TSTokenSize creditTokenInstance = TSTokenSize(creditToken);

        uint256 contractCreditTokenBalanceBefore = creditTokenInstance.balanceOf(
            address(takasureReserve)
        );
        uint256 aliceCreditTokenBalanceBefore = creditTokenInstance.balanceOf(alice);

        vm.prank(admin);
        joinModule.setKYCStatus(alice);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(alice);
        joinModule.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

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
