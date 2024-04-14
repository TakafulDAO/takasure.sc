//SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.24;

interface ITakasurePool {
    /// @notice Mint Taka tokens
    /// @dev It calls the mint function from the TakaToken contract
    /// @dev Reverts if the mint function fails
    /// @param to The address to mint tokens to
    /// @param amountToMint The amount of tokens to mint
    function mintTakaToken(address to, uint256 amountToMint) external returns (bool minted);

    /// @notice Burn Taka tokens
    /// @dev It calls the burn function from the TakaToken contract
    /// @param amountToBurn The amount of tokens to burn
    /// @param from The address to burn tokens from
    function burnTakaToken(uint256 amountToBurn, address from) external;

    /// @notice Get the address of the Taka token
    function getTakaTokenAddress() external view returns (address);

    /// @notice Get the amount of minted tokens by a user
    /// @param user The address of the user
    function getMintedTokensByUser(address user) external view returns (uint256);
}
