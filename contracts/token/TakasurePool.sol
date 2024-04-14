//SPDX-License-Identifier: GPL-3.0

/**
 * @title TakaSurePool
 * @author Maikel Ordaz
 * @dev This contract will have minter and burner roles to mint and burn Taka tokens
 */

pragma solidity 0.8.24;

import {TakaToken} from "./TakaToken.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TakasurePool is ReentrancyGuard {
    TakaToken private immutable takaToken;

    mapping(address user => uint256 balance) private userBalance;

    event TakaTokenMinted(address indexed to, uint256 indexed amount);
    event TakaTokenBurned(address indexed from, uint256 indexed amount);

    error TakaSurePool__NotZeroAddress();
    error TakaSurePool__MintFailed();
    error TakaSurePool__BurnAmountExceedsBalance(uint256 balance, uint256 amountToBurn);
    error TakaSurePool__TransferFailed();

    constructor(address _takaToken) {
        takaToken = TakaToken(_takaToken);
    }

    /// @notice Mint Taka tokens
    /// @dev It calls the mint function from the TakaToken contract
    /// @dev Reverts if the mint function fails
    /// @param to The address to mint tokens to
    /// @param amountToMint The amount of tokens to mint
    // Todo: Need access control?
    function mintTakaToken(
        address to,
        uint256 amountToMint
    ) external nonReentrant returns (bool minted) {
        if (to == address(0)) {
            revert TakaSurePool__NotZeroAddress();
        }

        userBalance[to] += amountToMint;

        minted = takaToken.mint(to, amountToMint);
        if (!minted) {
            revert TakaSurePool__MintFailed();
        }

        emit TakaTokenMinted(to, amountToMint);
    }

    /// @notice Burn Taka tokens
    /// @dev It calls the burn function from the TakaToken contract
    /// @param amountToBurn The amount of tokens to burn
    /// @param from The address to burn tokens from
    // Todo: Need access control?
    function burnTakaToken(uint256 amountToBurn, address from) external nonReentrant {
        if (from == address(0)) {
            revert TakaSurePool__NotZeroAddress();
        }
        if (amountToBurn > userBalance[from]) {
            revert TakaSurePool__BurnAmountExceedsBalance(userBalance[from], amountToBurn);
        }

        userBalance[from] -= amountToBurn;

        bool success = takaToken.transferFrom(from, address(this), amountToBurn);
        takaToken.burn(amountToBurn);
        if (!success) {
            revert TakaSurePool__TransferFailed();
        }

        emit TakaTokenBurned(from, amountToBurn);
    }

    /// @notice Get the address of the Taka token
    function getTakaTokenAddress() external view returns (address) {
        return address(takaToken);
    }

    /// @notice Get the amount of minted tokens by a user
    /// @param user The address of the user
    function getMintedTokensByUser(address user) external view returns (uint256) {
        return userBalance[user];
    }
}
