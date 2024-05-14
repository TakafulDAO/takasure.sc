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
        // vm.startPrank(user);
        // usdc.mintUSDC(user, USDC_INITIAL_AMOUNT);
        // usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        // vm.stopPrank();

        handler = new TakasurePoolHandler(takasurePool);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = TakasurePoolHandler.joinPool.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_someInvariant() public pure returns (bool) {
        return true;
    }
}
