// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {USDC} from "test/mocks/USDCmock.sol";

contract ApproveSpender is Script, GetContractAddress {
    uint256 public constant CONTRIUTION_AMOUNNT = 25 * 10 ** 6; // 25 USDC

    function run() public {
        address usdcAddress = _getContractAddress(block.chainid, "USDC");
        address takasureAddress = _getContractAddress(block.chainid, "TakasurePool");
        USDC usdc = USDC(usdcAddress);

        vm.startBroadcast();

        usdc.approve(takasureAddress, CONTRIUTION_AMOUNNT);

        vm.stopBroadcast();
    }
}
