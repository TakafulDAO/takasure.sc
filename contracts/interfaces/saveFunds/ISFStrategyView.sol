// SPDX-License-Identifier: GPL-3.0-only

import {StrategyConfig} from "contracts/types/Strategies.sol";

pragma solidity 0.8.28;

// Debugging and view functions for strategies.
interface ISFStrategyView {
    function getConfig() external view returns (StrategyConfig memory);
    function positionValue() external view returns (uint256);
    function getPositionDetails() external view returns (bytes memory);
}

