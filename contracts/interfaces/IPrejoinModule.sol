// SPDX-License-Identifier: GPL-3.0-only

pragma solidity 0.8.28;

interface IPrejoinModule {
    function getPrepaidMember(
        address member
    )
        external
        view
        returns (
            uint256 contributionBeforeFee,
            uint256 contributionAfterFee,
            uint256 feeToOperator,
            uint256 discount
        );
    function isMemberKYCed(address member) external view returns (bool);
}
