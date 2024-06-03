// SPDX-License-Identifier: GPL-3.0

/**
 * @title The Life DAO Token
 * @author Maikel Ordaz
 * @notice This is a utility token used exclusively within the Life DAO ecosystem.
 * @notice Minting: Algorithmic
 * @dev Minting and burning of the The Life DAO Token based on new members' admission into the pool, and members
 *      leaving due to inactivity or claims.
 */
pragma solidity 0.8.25;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TakaToken is ERC20Burnable, AccessControl, ReentrancyGuard {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    event TakaTokenMinted(address indexed to, uint256 indexed amount);
    event TakaTokenBurned(address indexed from, uint256 indexed amount);

    error TakaToken__NotZeroAddress();
    error TakaToken__MustBeMoreThanZero();
    error TakaToken__BurnAmountExceedsBalance(uint256 balance, uint256 amountToBurn);

    modifier mustBeMoreThanZero(uint256 _amount) {
        if (_amount <= 0) {
            revert TakaToken__MustBeMoreThanZero();
        }
        _;
    }

    constructor() ERC20("The Life DAO", "TLD") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); // TODO: Discuss. Who? The Dao?
        // Todo: Discuss. Allow someone here as Minter and Burner?
    }

    /** @notice Mint The Life DAO Token
     * @dev Reverts if the address is the zero addresss
     * @param to The address to mint tokens to
     * @param amountToMint The amount of tokens to mint
     */
    function mint(
        address to,
        uint256 amountToMint
    ) external nonReentrant onlyRole(MINTER_ROLE) mustBeMoreThanZero(amountToMint) returns (bool) {
        if (to == address(0)) {
            revert TakaToken__NotZeroAddress();
        }
        _mint(to, amountToMint);
        emit TakaTokenMinted(to, amountToMint);

        return true;
    }

    /**
     * @notice Burn The Life DAO Token
     * @param amountToBurn The amount of tokens to burn
     * @dev Reverts if the amount to burn is more than the sender's balance
     */
    function burn(
        uint256 amountToBurn
    ) public override nonReentrant onlyRole(BURNER_ROLE) mustBeMoreThanZero(amountToBurn) {
        uint256 balance = balanceOf(msg.sender);
        if (amountToBurn > balance) {
            revert TakaToken__BurnAmountExceedsBalance(balance, amountToBurn);
        }
        emit TakaTokenBurned(msg.sender, amountToBurn);

        super.burn(amountToBurn);
    }
}
