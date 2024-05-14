// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, StdInvariant, console2} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../contracts/takasure/TakasurePool.sol";
import {IUSDC} from "../../../contracts/mocks/IUSDCmock.sol";
import {TakasurePoolHandler} from "./handlers/TakasurePoolHandler.t.sol";

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

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TakasurePoolHandler.joinPool.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Invariant to check pool contribution token balance and reserves
    /// pool_contribution_token_balance = claim_reserves + fund_reserves
    // ? Question: is this true? Right now it is, but it may not be in the future with the claims? R&D
    function invariant_reservesShouldBeEqualToBalance() public view {
        uint256 contributionTokenBalance = usdc.balanceOf(address(takasurePool));

        (, , , , uint256 claimReserve, uint256 fundReserve, ) = takasurePool.getPoolValues();
        uint256 reserves = claimReserve + fundReserve;

        console2.log("contributionTokenBalance", contributionTokenBalance);
        console2.log("reserves", reserves);

        assertEq(contributionTokenBalance, reserves);
    }
}
