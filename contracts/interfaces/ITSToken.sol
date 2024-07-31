//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

interface ITSToken {
    /// @notice Mint Takasure powered tokens
    /// @param to The address to mint tokens to
    /// @param amountToMint The amount of tokens to mint
    function mint(address to, uint256 amountToMint) external returns (bool);

    /// @notice Burn Takasure powered tokens
    /// @param amountToBurn The amount of tokens to burn
    function burn(uint256 amountToBurn) external;
}
