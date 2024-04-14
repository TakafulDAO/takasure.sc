// SPDX-License-Identifier: GPL-3.0

/**
 * @title TakaToken
 * @author Maikel Ordaz
 * @notice Minting: Algorithmic
 * @dev Minting and burning of the TAKA token based on new members' admission into the pool, and members
 *      leaving due to inactivity or claims.
 */

pragma solidity 0.8.24;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract TakaToken is ERC20Burnable, AccessControl {
    // TODO: Name? Symbol? Decimals? Total supply?
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    error TakaToken__MustBeMoreThanZero();
    error TakaToken__BurnAmountExceedsBalance();
    error TakaToken__NotZeroAddress();

    constructor() ERC20("TAKA", "TKS") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); // TODO: Discuss. Who? The Dao?
        // Todo: Discuss. Allow someone here as Minter and Burner?
    }

    /// @dev Burn tokens from the owner's balance
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) public override onlyRole(BURNER_ROLE) {
        // Todo: Discuss. If only TakasurePool will be burner this is redundant
        if (amount <= 0) {
            revert TakaToken__MustBeMoreThanZero();
        }

        uint256 balance = balanceOf(msg.sender);
        // Todo: Discuss. If only TakasurePool will be burner this is redundant
        if (balance < amount) {
            revert TakaToken__BurnAmountExceedsBalance();
        }

        super.burn(amount);
    }

    /// @dev Mint new tokens
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) returns (bool) {
        // Todo: Discuss. If only TakasurePool will be minter this is redundant
        if (to == address(0)) {
            revert TakaToken__NotZeroAddress();
        }
        if (amount <= 0) {
            revert TakaToken__MustBeMoreThanZero();
        }

        _mint(to, amount);

        return true;
    }
}
