// SPDX-License-Identifier: GPL-3.0

/**
 * @title Takasure Token
 * @author Maikel Ordaz
 * @notice Minting: Algorithmic
 * @notice This contract can be re-used to create any token powered by Takasure to be used in other DAOs.
 * @dev Minting and burning of the this utility token based on new members' admission into the pool, and members
 *      leaving due to inactivity or claims.
 */
pragma solidity 0.8.25;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TSToken is ERC20Burnable, AccessControl, ReentrancyGuard {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    event OnTokenMinted(address indexed to, uint256 indexed amount);
    event OnTokenBurned(address indexed from, uint256 indexed amount);

    error Token__NotZeroAddress();
    error Token__MustBeMoreThanZero();
    error Token__BurnAmountExceedsBalance(uint256 balance, uint256 amountToBurn);

    modifier mustBeMoreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert Token__MustBeMoreThanZero();
        }
        _;
    }

    constructor(
        address admin,
        string memory tokenName,
        string memory tokenSymbol
    ) ERC20(tokenName, tokenSymbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, msg.sender);
        _grantRole(BURNER_ROLE, msg.sender);
    }

    /** @notice Mint Takasure powered tokens
     * @dev Reverts if the address is the zero addresss
     * @param to The address to mint tokens to
     * @param amountToMint The amount of tokens to mint
     */
    function mint(
        address to,
        uint256 amountToMint
    ) external nonReentrant onlyRole(MINTER_ROLE) mustBeMoreThanZero(amountToMint) returns (bool) {
        if (to == address(0)) {
            revert Token__NotZeroAddress();
        }
        _mint(to, amountToMint);
        emit OnTokenMinted(to, amountToMint);

        return true;
    }

    /**
     * @notice Burn Takasure powered tokens
     * @param amountToBurn The amount of tokens to burn
     * @dev Reverts if the amount to burn is more than the sender's balance
     */
    function burn(
        uint256 amountToBurn
    ) public override nonReentrant onlyRole(BURNER_ROLE) mustBeMoreThanZero(amountToBurn) {
        uint256 balance = balanceOf(msg.sender);
        if (amountToBurn > balance) {
            revert Token__BurnAmountExceedsBalance(balance, amountToBurn);
        }
        emit OnTokenBurned(msg.sender, amountToBurn);

        super.burn(amountToBurn);
    }
}
