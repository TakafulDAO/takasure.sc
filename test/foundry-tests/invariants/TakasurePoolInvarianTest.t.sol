// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, StdInvariant, console2} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../contracts/takasure/TakasurePool.sol";
import {IUSDC} from "../../../contracts/mocks/IUSDCmock.sol";
import {TakasurePoolHandler} from "../helpers/handlers/TakasurePoolHandler.t.sol";

contract TakasurePoolInvariantTest is StdInvariant, Test {
    DeployTokenAndPool deployer;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;
    TakasurePoolHandler handler;
    address contributionTokenAddress;
    IUSDC usdc;
    address public user = makeAddr("user");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (, proxy, , contributionTokenAddress, ) = deployer.run();
        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        handler = new TakasurePoolHandler(takasurePool);

        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = TakasurePoolHandler.joinPool.selector;
        selectors[1] = TakasurePoolHandler.moveTime.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Invariant to check pool contribution token balance and reserves
    /// pool_contribution_token_balance = claim_reserves + fund_reserves
    // ? Question: is this true? Right now it is, but it may not be in the future with the claims? R&D
    function invariant_reservesShouldBeEqualToBalance() public view {
        uint256 contributionTokenBalance = usdc.balanceOf(address(takasurePool));

        (, , , , uint256 claimReserve, uint256 fundReserve, ) = takasurePool.getReserveValues();
        uint256 reserves = claimReserve + fundReserve;

        assertEq(contributionTokenBalance, reserves, "Reserves should be equal to balance");
    }

    /// @dev Invariant to check dynamic reserve ratio. Can not be greater than 100
    function invariant_dynamicReserveRatioCanNotBeGreaterThan100() public view {
        (
            uint256 proformaFundReserve,
            uint256 drr,
            ,
            uint256 totalContributions,
            uint256 totalClaimReserve,
            uint256 totalFundReserve,

        ) = takasurePool.getReserveValues();

        console2.log("Dynamic Reserve Ratio: ", drr);
        // console2.log("Month", takasurePool.monthReference());
        // console2.log("Day", takasurePool.dayReference());
        // console2.log("proforma fund reserve", proformaFundReserve);
        // console2.log("total contributions", totalContributions);
        // console2.log("total claim reserve", totalClaimReserve);
        // console2.log("total fund reserve", totalFundReserve);

        assert(drr <= 100);
    }

    /// forge-config: default.invariant.runs = 100
    /// forge-config: default.invariant.depth = 2
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_gettersShouldNotRevert() public view {
        takasurePool.getCashLast12Months();
        takasurePool.getContributionTokenAddress();
        takasurePool.getReserveValues();
        takasurePool.getTakaTokenAddress();
    }
}
