// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";

contract JoinPool is Script, GetContractAddress {
    uint256 public constant CONTRIBUTION_AMOUNT = 25 * 10 ** 6; // 25 USDC
    uint256 public constant MEMBERSHIP_DURATION = 5 * 365 days; // 5 years

    function run() public {
        address takasureAddress = _getContractAddress(block.chainid, "TakasurePool");
        TakasurePool takasurePool = TakasurePool(takasureAddress);

        vm.startBroadcast();

        (bool success, ) = takasureAddress.call{gas: type(uint256).max}(
            abi.encodeWithSelector(
                takasurePool.joinPool.selector,
                CONTRIBUTION_AMOUNT,
                MEMBERSHIP_DURATION
            )
        );

        vm.stopBroadcast();
    }
}
