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

contract JoinAccess_9690 is StdCheats, Test, SimulateDonResponse {
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
    address public victim = makeAddr("victim");
    address public malicious = makeAddr("malicious");
    address public parent = makeAddr("parent");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
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
        deal(address(usdc), victim, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(bob);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
        vm.startPrank(victim);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(admin);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(entryModuleAddress));

        vm.startPrank(takadao);
        entryModule.updateBmAddress();
        entryModule.grantRole(keccak256("ROUTER"), address(userRouter));
        vm.stopPrank();
    }

    /// Can be called by self or router. Anyone else should revert.
    function testEntryModule_joinPoolControlAccess() public {
        vm.prank(alice);
        entryModule.joinPool(alice, parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        vm.prank(bob);
        userRouter.joinPool(parent, CONTRIBUTION_AMOUNT, (5 * YEAR));

        vm.prank(malicious);
        vm.expectRevert(EntryModule.EntryModule__NotAuthorizedCaller.selector);
        entryModule.joinPool(victim, parent, CONTRIBUTION_AMOUNT, (5 * YEAR));
    }
}
