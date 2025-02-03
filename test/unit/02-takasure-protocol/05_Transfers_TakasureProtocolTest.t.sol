// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {EntryModule} from "contracts/takasure/modules/EntryModule.sol";
import {UserRouter} from "contracts/takasure/router/UserRouter.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Member, MemberState, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract Transfers_TakasureProtocolTest is StdCheats, Test {
    TestDeployTakasureReserve deployer;
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
            ,
            ,
            userRouterAddress,
            ,
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

        vm.startPrank(alice);
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
                    JOIN POOL::TRANSFER AMOUNTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Test contribution amount is not transferred to the contract if only the KYC is done
    function testTakasureReserve_contributionAmountNotTransferToContractWhenKycMissing() public {
        uint256 takasureReserveBalanceBefore = usdc.balanceOf(address(takasureReserve));
        uint256 entryModuleBalanceBefore = usdc.balanceOf(address(entryModule));

        vm.prank(alice);
        userRouter.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 takasureReserveBalanceAfter = usdc.balanceOf(address(takasureReserve));
        uint256 entryModuleBalanceAfter = usdc.balanceOf(address(entryModule));

        assertEq(takasureReserveBalanceAfter, takasureReserveBalanceBefore);
        assert(entryModuleBalanceAfter > entryModuleBalanceBefore);
    }

    /// @dev Test contribution amount is transferred to the contract when joins the pool
    function testTakasureReserve_contributionAmountTransferToContractWhenJoinPool() public {
        uint256 takasureReserveBalanceBefore = usdc.balanceOf(address(takasureReserve));
        uint256 entryModuleBalanceBefore = usdc.balanceOf(address(entryModule));

        Reserve memory reserve = takasureReserve.getReserveValues();
        uint8 serviceFee = reserve.serviceFee;

        vm.prank(alice);
        userRouter.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 takasureReserveBalanceAfter = usdc.balanceOf(address(takasureReserve));
        uint256 entryModuleBalanceAfter = usdc.balanceOf(address(entryModule));

        uint256 fee = (CONTRIBUTION_AMOUNT * serviceFee) / 100;
        uint256 deposited = CONTRIBUTION_AMOUNT - fee;

        assertEq(takasureReserveBalanceAfter, takasureReserveBalanceBefore);
        assertEq(entryModuleBalanceAfter, entryModuleBalanceBefore + deposited);
    }

    /// @dev Test service fee is transferred when the member joins the pool
    function testTakasureReserve_serviceFeeAmountTransferedWhenJoinsPool() public {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint8 serviceFee = reserve.serviceFee;
        address serviceFeeReceiver = takasureReserve.feeClaimAddress();
        uint256 serviceFeeReceiverBalanceBefore = usdc.balanceOf(serviceFeeReceiver);

        vm.prank(alice);
        userRouter.joinPool(CONTRIBUTION_AMOUNT, (5 * YEAR));

        uint256 serviceFeeReceiverBalanceAfter = usdc.balanceOf(serviceFeeReceiver);

        uint256 feeColected = (CONTRIBUTION_AMOUNT * serviceFee) / 100; // 25USDC * 20% = 5USDC

        assertEq(serviceFeeReceiverBalanceAfter, serviceFeeReceiverBalanceBefore + feeColected);
    }
}
