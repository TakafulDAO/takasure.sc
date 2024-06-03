//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

interface ITLDToken {
    /// @notice Mint The Life DAO Token
    /// @dev It calls the mint function from the The Life DAO Token contract
    /// @dev Reverts if the mint function fails
    /// @param to The address to mint tokens to
    /// @param amountToMint The amount of tokens to mint
    function mint(address to, uint256 amountToMint) external returns (bool);

    /// @notice Burn Taka tokens
    /// @dev It calls the burn function from the The Life DAO Token contract
    /// @param from The address to burn tokens from
    /// @param amountToBurn The amount of tokens to burn
    function burnTokens(address from, uint256 amountToBurn) external;

    /// @notice Get the amount of minted tokens by a user
    /// @param user The address of the user
    function getMintedTokensByUser(address user) external view returns (uint256);
}
