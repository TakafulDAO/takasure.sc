// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.24;

interface ITakaToken {
    /// @dev Burn tokens from the owner's balance
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) external;

    /// @dev Mint new tokens
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external returns (bool);
}
