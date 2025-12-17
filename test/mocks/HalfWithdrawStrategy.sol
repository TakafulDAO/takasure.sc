// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestSubStrategy} from "test/mocks/TestSubStrategy.sol";

contract HalfWithdrawStrategy is TestSubStrategy {
    constructor(IERC20 _underlying) TestSubStrategy(_underlying) {}

    // Return only half of what would normally be withdrawn (to force "loss" branches)
    function withdraw(uint256 assets, address receiver, bytes calldata data)
        public
        override
        returns (uint256 withdrawn)
    {
        // ask parent to send up to `assets`, but we only want half of requested.
        // simplest: request half from the base implementation.
        uint256 halfReq = assets / 2;
        if (halfReq == 0) return 0;

        return super.withdraw(halfReq, receiver, data);
    }

    function test() public override {}
}
