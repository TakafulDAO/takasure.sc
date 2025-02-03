// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {EntryModule} from "contracts/takasure/modules/EntryModule.sol";
import {MemberModule} from "contracts/takasure/modules/MemberModule.sol";
import {UserRouter} from "contracts/takasure/router/UserRouter.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract TakasureProtocolFuzzTest is Test {
    TestDeployTakasureReserve deployer;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    EntryModule entryModule;
    MemberModule memberModule;
    UserRouter userRouter;
    BenefitMultiplierConsumerMock bmConsumerMock;
    address takasureReserveProxy;
    address contributionTokenAddress;
    address daoMultisig;
    address takadao;
    address entryModuleAddress;
    address memberModuleAddress;
    address userRouterAddress;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        deployer = new TestDeployTakasureReserve();
        (
            ,
            bmConsumerMock,
            takasureReserveProxy,
            entryModuleAddress,
            memberModuleAddress,
            ,
            userRouterAddress,
            ,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        entryModule = EntryModule(entryModuleAddress);
        memberModule = MemberModule(memberModuleAddress);
        userRouter = UserRouter(userRouterAddress);

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        daoMultisig = config.daoMultisig;
        takadao = config.takadaoOperator;

        takasureReserve = TakasureReserve(takasureReserveProxy);
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(entryModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(memberModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(daoMultisig);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(entryModuleAddress));

        vm.prank(takadao);
        entryModule.updateBmAddress();
    }

    function test_fuzz_ownerCanSetKycstatus(address notOwner) public {
        vm.assume(notOwner != daoMultisig);

        vm.prank(alice);
        userRouter.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        vm.prank(notOwner);
        vm.expectRevert();
        entryModule.setKYCStatus(alice);
    }

    function test_fuzz_onlyDaoAndTakadaoCanSetNewBenefitMultiplier(address notAuthorized) public {
        vm.assume(notAuthorized != daoMultisig && notAuthorized != takadao);

        vm.prank(notAuthorized);
        vm.expectRevert();
        takasureReserve.setNewBenefitMultiplierConsumerAddress(alice);
    }
}
