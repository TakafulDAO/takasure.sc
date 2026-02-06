// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {MockERC20} from "forge-std/mocks/MockERC20.sol";

contract TestERC20 is MockERC20 {
    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        initialize(name_, symbol_, decimals_);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
