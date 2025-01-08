// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface IReferralGateway {
    function testCaller(
        address caller,
        uint256 callUint
    ) external view returns (address, uint256, address);
}
