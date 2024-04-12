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

    constructor(address defaultAdmin, address minter, address burner) ERC20("TAKA", "TKS") {
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin); // TODO: Discuss. Who? The Dao?
        // Todo: Discuss. Someone else beside the contract that allow to join the fund?
        _grantRole(MINTER_ROLE, minter);
        _grantRole(BURNER_ROLE, burner);
    }

    /// @dev Burn tokens from the owner's balance
    /// @param amount The amount of tokens to burn
    function burn(uint256 amount) public override onlyRole(MINTER_ROLE) {
        if (amount <= 0) {
            revert TakaToken__MustBeMoreThanZero();
        }

        uint256 balance = balanceOf(msg.sender);
        if (balance < amount) {
            revert TakaToken__BurnAmountExceedsBalance();
        }

        super.burn(amount);
    }

    /// @dev Mint new tokens
    /// @param to The address to mint tokens to
    /// @param amount The amount of tokens to mint
    function mint(address to, uint256 amount) external onlyRole(BURNER_ROLE) returns (bool) {
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
