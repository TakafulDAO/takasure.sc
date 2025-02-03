// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, StdInvariant, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {TakasureReserve} from "contracts/takasure/core/TakasureReserve.sol";
import {EntryModule} from "contracts/takasure/modules/EntryModule.sol";
import {MemberModule} from "contracts/takasure/modules/MemberModule.sol";
import {UserRouter} from "contracts/takasure/router/UserRouter.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {TakasureProtocolHandler} from "test/helpers/handlers/TakasureProtocolHandler.t.sol";

contract TakasureProtocolInvariantTest is StdInvariant, Test {
    TestDeployTakasureReserve deployer;
    TakasureReserve takasureReserve;
    EntryModule entryModule;
    MemberModule memberModule;
    TakasureProtocolHandler handler;
    UserRouter userRouter;
    address takasureReserveProxy;
    address entryModuleAddress;
    address memberModuleAddress;
    address contributionTokenAddress;
    address userRouterAddress;
    IUSDC usdc;
    address public user = makeAddr("user");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        deployer = new TestDeployTakasureReserve();
        (
            ,
            ,
            takasureReserveProxy,
            entryModuleAddress,
            memberModuleAddress,
            ,
            userRouterAddress,
            ,
            contributionTokenAddress,
            ,

        ) = deployer.run();

        takasureReserve = TakasureReserve(address(takasureReserveProxy));
        entryModule = EntryModule(entryModuleAddress);
        memberModule = MemberModule(memberModuleAddress);
        userRouter = UserRouter(userRouterAddress);
        usdc = IUSDC(contributionTokenAddress);

        handler = new TakasureProtocolHandler(
            takasureReserve,
            entryModule,
            memberModule,
            userRouter
        );

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = TakasureProtocolHandler.joinPool.selector;
        selectors[1] = TakasureProtocolHandler.moveTime.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Invariant to check pool contribution token balance and reserves
    /// pool_contribution_token_balance = claim_reserves + fund_reserves
    // ? Question: is this true? Right now it is, but it may not be in the future with the claims? R&D
    // function invariant_reservesShouldBeEqualToBalance() public view {
    //     uint256 contributionTokenBalance = usdc.balanceOf(address(takasurePool));

    //     (, , , , uint256 claimReserve, uint256 fundReserve, , , , , , ) = takasurePool
    //         .getReserveValues();
    //     uint256 reserves = claimReserve + fundReserve;

    //     assertEq(contributionTokenBalance, reserves, "Reserves should be equal to balance");
    // }

    /// @dev Invariant to check dynamic reserve ratio. Can not be greater than 100
    // function invariant_dynamicReserveRatioCanNotBeGreaterThan100() public view {
    //     (, uint256 drr, , , , , , , , , , ) = takasurePool.getReserveValues();

    //     console2.log("Dynamic Reserve Ratio: ", drr);

    //     assert(drr <= 100);
    // }

    /// @dev Invariant to check BMA can not be greater than 100
    // function invariant_bmaCanNotBeGreaterThan100() public view {
    //     (, , uint256 bma, , , , , , , , , ) = takasurePool.getReserveValues();

    //     console2.log("BMA: ", bma);

    //     assert(bma <= 100);
    // }

    /// @dev Invariant to check if getters do not revert
    /// forge-config: default.invariant.runs = 100
    /// forge-config: default.invariant.depth = 2
    /// forge-config: default.invariant.fail-on-revert = true
    // function invariant_gettersShouldNotRevert() public view {
    //     takasurePool.getCashLast12Months();
    //     takasurePool.getContributionTokenAddress();
    //     takasurePool.getReserveValues();
    //     takasurePool.getDaoTokenAddress();
    // }
}
