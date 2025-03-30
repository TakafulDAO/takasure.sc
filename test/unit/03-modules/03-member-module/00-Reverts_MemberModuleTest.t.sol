// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract Reverts_MemberModuleTest is StdCheats, Test, SimulateDonResponse {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    EntryModule entryModule;
    MemberModule memberModule;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address admin;
    address takadao;
    address entryModuleAddress;
    address memberModuleAddress;
    address revShareModuleAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
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
            memberModuleAddress,
            ,
            revShareModuleAddress,
            ,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        entryModule = EntryModule(entryModuleAddress);
        memberModule = MemberModule(memberModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(memberModule), USDC_INITIAL_AMOUNT);
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

    /// @dev `payRecurringContribution` must revert if the member is invalid
    function testMemberModule_payRecurringContributionMustRevertIfMemberIsInvalid() public {
        vm.prank(alice);
        vm.expectRevert(ModuleErrors.Module__WrongMemberState.selector);
        memberModule.payRecurringContribution(alice);
    }

    /// @dev `payRecurringContribution` must revert if the date is invalid, a year has passed and the member has not paid
    function testMemberModule_payRecurringContributionMustRevertIfDateIsInvalidNotPaidInTime()
        public
    {
        vm.startPrank(alice);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        entryModule.joinPool(alice, parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.setKYCStatus(alice);

        vm.warp(block.timestamp + 396 days);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        vm.expectRevert(MemberModule.MemberModule__InvalidDate.selector);
        memberModule.payRecurringContribution(alice);
        vm.stopPrank();
    }

    /// @dev `payRecurringContribution` must revert if the date is invalid, the membership expired
    function testMemberModule_payRecurringContributionMustRevertIfDateIsInvalidMembershipExpired()
        public
    {
        vm.startPrank(alice);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        entryModule.joinPool(alice, parent, CONTRIBUTION_AMOUNT, 5 * YEAR);
        vm.stopPrank();

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        vm.prank(admin);
        entryModule.setKYCStatus(alice);

        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + YEAR);
            vm.roll(block.number + 1);

            vm.startPrank(alice);
            memberModule.payRecurringContribution(alice);
            vm.stopPrank();
        }

        vm.warp(block.timestamp + YEAR);
        vm.roll(block.number + 1);

        vm.startPrank(alice);
        vm.expectRevert(MemberModule.MemberModule__InvalidDate.selector);
        memberModule.payRecurringContribution(alice);
    }
}
