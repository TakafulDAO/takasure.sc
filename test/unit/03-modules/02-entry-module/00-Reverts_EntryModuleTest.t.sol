// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {UserRouter} from "contracts/router/UserRouter.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Reverts_EntryModuleTest is StdCheats, Test, SimulateDonResponse {
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
    address revShareModuleAddress;
    address userRouterAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public david = makeAddr("david");
    address public parent = makeAddr("parent");
    uint256 public constant USDC_INITIAL_AMOUNT = 150e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
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
            revShareModuleAddress,
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
        deal(address(usdc), charlie, USDC_INITIAL_AMOUNT);
        deal(address(usdc), david, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(charlie);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(david);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(entryModuleAddress));

        vm.startPrank(takadao);
        entryModule.updateBmAddress();
        entryModule.setRevShareModule(revShareModuleAddress);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @dev `joinPool` must revert if the contribution is less than the minimum threshold
    function testEntryModule_joinPoolMustRevertIfDepositLessThanMinimum() public {
        uint256 wrongContribution = CONTRIBUTION_AMOUNT / 2;
        vm.prank(alice);
        vm.expectRevert(EntryModule.EntryModule__ContributionOutOfRange.selector);
        userRouter.joinPool(parent, wrongContribution, (5 * YEAR));
    }

    /// @dev If it is an active member, can not join again
    function testEntryModule_activeMembersShouldNotJoinAgain() public {
        vm.prank(alice);
        // Alice joins the pool
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.setKYCStatus(alice);

        vm.prank(alice);
        // And tries to join again but fails
        vm.expectRevert(ModuleErrors.Module__WrongMemberState.selector);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));
    }

    /// @dev `setKYCStatus` must revert if the member is address zero
    function testEntryModule_setKYCStatusMustRevertIfMemberIsAddressZero() public {
        vm.prank(admin);

        vm.expectRevert(AddressAndStates.TakasureProtocol__ZeroAddress.selector);
        entryModule.setKYCStatus(address(0));
    }

    /// @dev `setKYCStatus` must revert if the member is already KYC verified
    function testEntryModule_setKYCStatusMustRevertIfMemberIsAlreadyKYCVerified() public {
        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.startPrank(admin);
        entryModule.setKYCStatus(alice);

        // And tries to join again but fails
        vm.expectRevert(EntryModule.EntryModule__MemberAlreadyKYCed.selector);
        entryModule.setKYCStatus(alice);

        vm.stopPrank();
    }

    /// @dev can not refund someone already KYC verified
    function testEntryModule_refundRevertIfMemberIsKyc() public {
        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.setKYCStatus(alice);

        vm.prank(alice);
        vm.expectRevert(EntryModule.EntryModule__MemberAlreadyKYCed.selector);
        entryModule.refund();
    }

    /// @dev can not refund someone already refunded
    function testEntryModule_refundRevertIfMemberAlreadyRefunded() public {
        vm.startPrank(alice);
        // Join and refund
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        entryModule.refund();

        // Try to refund again
        vm.expectRevert(EntryModule.EntryModule__NothingToRefund.selector);
        entryModule.refund();
        vm.stopPrank();
    }

    /// @dev can not refund before 14 days
    function testEntryModule_refundRevertIfMemberRefundBefore14Days() public {
        // Join
        vm.startPrank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // Try to refund
        vm.startPrank(alice);
        vm.expectRevert(EntryModule.EntryModule__TooEarlytoRefund.selector);
        entryModule.refund();
        vm.stopPrank();
    }

    function testEntryModule_revertIfTryToJoinTwice() public {
        // First check alice join -> kyc alice -> alice join again must revert
        vm.prank(alice);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.setKYCStatus(alice);

        vm.prank(alice);
        vm.expectRevert(ModuleErrors.Module__WrongMemberState.selector);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);

        // Second check bob join -> bob join again must revert
        vm.startPrank(bob);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.expectRevert(EntryModule.EntryModule__AlreadyJoinedPendingForKYC.selector);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // Third check charlie join -> 14 days passes -> refund charlie -> charlie join -> kyc charlie -> charlie join again must revert
        vm.prank(charlie);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.warp(block.timestamp + 15 days);
        vm.roll(block.number + 1);

        vm.startPrank(charlie);
        userRouter.refund();
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        vm.prank(admin);
        entryModule.setKYCStatus(charlie);

        vm.prank(charlie);
        vm.expectRevert(ModuleErrors.Module__WrongMemberState.selector);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);

        // Fourth check david join -> 14 days passes -> refund david -> david join -> david join again must revert
        vm.prank(david);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);

        vm.warp(block.timestamp + 15 days);
        vm.roll(block.number + 1);

        vm.startPrank(david);
        userRouter.refund();
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.expectRevert(EntryModule.EntryModule__AlreadyJoinedPendingForKYC.selector);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();
    }
}
