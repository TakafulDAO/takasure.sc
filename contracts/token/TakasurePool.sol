//SPDX-License-Identifier: GPL-3.0

/**
 * @title TakaSurePool
 * @author Maikel Ordaz
 * @dev this contract will have minter and burner roles to mint and burn Taka tokens
 */

pragma solidity 0.8.24;

import {TakaToken} from "./TakaToken.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TakaSurePool is ReentrancyGuard {
    error TakaSurePool__MintFailed();

    mapping(address user => uint256 tokensMinted) private mintedTokens;

    TakaToken private immutable takaToken;

    event TakaTokenMinted(address indexed to, uint256 indexed amount);

    constructor(address takaTokenAddress) {
        takaToken = TakaToken(takaTokenAddress);
    }

    /// @notice Mint Taka tokens
    /// @dev It calls the mint function from the TakaToken contract
    /// @dev Reverts if the mint function fails
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mintTakaToken(address to, uint256 amount) external nonReentrant {
        mintedTokens[to] += amount;

        bool minted = takaToken.mint(to, amount);
        if (!minted) {
            revert TakaSurePool__MintFailed();
        }

        emit TakaTokenMinted(to, amount);
    }

    function getTakaTokenAddress() external view returns (address) {
        return address(takaToken);
    }

    /// @notice Get the amount of minted tokens by a user
    /// @param user The address of the user
    function getMintedTokensByUser(address user) external view returns (uint256) {
        return mintedTokens[user];
    }
}
