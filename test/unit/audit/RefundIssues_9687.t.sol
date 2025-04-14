// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";

contract RefundIssue_9687 is StdCheats, Test, SimulateDonResponse {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    BenefitMultiplierConsumerMock bmConsumerMock;
    PrejoinModule prejoinModule;
    EntryModule entryModule;
    address takasureReserveAddress;
    address contributionTokenAddress;
    address admin;
    address kycService;
    address takadao;
    address prejoinModuleAddress;
    address entryModuleAddress;
    address revShareModuleAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    address public parent = makeAddr("parent");
    uint256 public constant USDC_INITIAL_AMOUNT = 10000e6; // 10000 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 250e6; // 250 USD
    uint256 public constant YEAR = 365 days;
    string tDaoName = "TheLifeDao";

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            ,
            bmConsumerMock,
            takasureReserveAddress,
            prejoinModuleAddress,
            entryModuleAddress,
            ,
            ,
            ,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        prejoinModule = PrejoinModule(prejoinModuleAddress);
        takasureReserve = TakasureReserve(takasureReserveAddress);
        entryModule = EntryModule(entryModuleAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        admin = config.daoMultisig;
        kycService = config.kycProvider;
        takadao = config.takadaoOperator;

        usdc = IUSDC(contributionTokenAddress);

        vm.startPrank(alice);
        usdc.approve(address(prejoinModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.startPrank(admin);
        takasureReserve.setNewContributionToken(address(usdc));
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));
        prejoinModule.createDAO(tDaoName, true, true, 1743479999, 1e12, address(bmConsumerMock));
        prejoinModule.setDAOName(tDaoName);
        vm.stopPrank();

        vm.startPrank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(takasureReserve));
        bmConsumerMock.setNewRequester(prejoinModuleAddress);
        bmConsumerMock.setNewRequester(address(entryModuleAddress));
        vm.stopPrank();

        vm.prank(takadao);
        entryModule.updateBmAddress();

        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);
    }

    // Alice joins, refund, and call joinDAO in the prejoin module, reverts. No risk
    function testEntryModule_refundIssueViaPrejoin1() public {
        deal(address(usdc), address(entryModule), USDC_INITIAL_AMOUNT);

        (, , , , uint256 launchDate, , , , , , ) = prejoinModule.getDAOData();

        vm.warp(launchDate + 1);
        vm.roll(block.number + 1);

        vm.startPrank(admin);
        prejoinModule.launchDAO(address(takasureReserve), entryModuleAddress, true);
        vm.stopPrank();

        vm.prank(alice);
        entryModule.joinPool(alice, parent, CONTRIBUTION_AMOUNT, 5 * YEAR);

        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        Member memory aliceBeforeRefund = takasureReserve.getMemberFromAddress(alice);

        assert(aliceBeforeRefund.memberState == MemberState.Inactive);
        assert(!aliceBeforeRefund.isKYCVerified);
        assert(!aliceBeforeRefund.isRefunded);

        // 14 days passed
        vm.warp(aliceBeforeRefund.membershipStartTime + 15 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        entryModule.refund();

        Member memory aliceAfterRefund = takasureReserve.getMemberFromAddress(alice);

        assert(aliceAfterRefund.memberState == MemberState.Inactive);
        assert(!aliceAfterRefund.isKYCVerified);
        assert(aliceAfterRefund.isRefunded);

        vm.prank(alice);
        vm.expectRevert(PrejoinModule.PrejoinModule__NotKYCed.selector);
        prejoinModule.joinDAO(alice);
    }

    function testEntryModule_refundIssueViaSetKYC() public {
        deal(address(usdc), address(entryModule), USDC_INITIAL_AMOUNT);

        vm.prank(alice);
        entryModule.joinPool(alice, parent, CONTRIBUTION_AMOUNT, 5 * YEAR);

        uint256 aliceExpectedBalanceBeforeRefund = USDC_INITIAL_AMOUNT - CONTRIBUTION_AMOUNT; // 10000 - 250 = 9750
        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));

        Member memory aliceBeforeRefund = takasureReserve.getMemberFromAddress(alice);

        assert(aliceBeforeRefund.memberState == MemberState.Inactive);
        assert(!aliceBeforeRefund.isKYCVerified);
        assert(!aliceBeforeRefund.isRefunded);
        assertEq(usdc.balanceOf(alice), aliceExpectedBalanceBeforeRefund);

        // 14 days passed
        vm.warp(15 days);
        vm.roll(block.number + 1);

        vm.prank(alice);
        entryModule.refund();

        Member memory aliceAfterRefund = takasureReserve.getMemberFromAddress(alice);

        uint256 aliceExpectedBalanceAfterRefund = aliceExpectedBalanceBeforeRefund +
            CONTRIBUTION_AMOUNT -
            ((CONTRIBUTION_AMOUNT * 27) / 100);

        assert(aliceAfterRefund.memberState == MemberState.Inactive);
        assert(!aliceAfterRefund.isKYCVerified);
        assert(aliceAfterRefund.isRefunded);
        assertEq(usdc.balanceOf(alice), aliceExpectedBalanceAfterRefund);

        vm.prank(kycService);
        vm.expectRevert();
        entryModule.setKYCStatus(alice);
    }
}
