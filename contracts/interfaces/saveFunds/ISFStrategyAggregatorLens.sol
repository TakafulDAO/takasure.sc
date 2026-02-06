// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title SFStrategyAggregatorLens
 * @author Maikel Ordaz
 * @notice View-only helper for SFStrategyAggregator.
 */

pragma solidity 0.8.28;

import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {SubStrategy} from "contracts/types/Strategies.sol";

interface ISFStrategyAggregatorLens {
    function asset() external view returns (address);
    function paused() external view returns (bool);
    function addressManager() external view returns (IAddressManager);
    function getSubStrategies() external view returns (SubStrategy[] memory);
}
