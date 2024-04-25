// SPDX-License-Identifier: GPL-3.0

/**
 * @title TakasurePool
 * @author Maikel Ordaz
 * @notice Minting: Algorithmic
 * @dev Minting and burning of the TAKA token based on new members' admission into the pool, and members
 *      leaving due to inactivity or claims.
 */

pragma solidity 0.8.25;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract TakasurePool is ERC20Burnable, AccessControl, ReentrancyGuard {
    // TODO: Decimals? Total supply?
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    mapping(address user => uint256 balance) private userBalance;

    event TakaTokenMinted(address indexed to, uint256 indexed amount);
    event TakaTokenBurned(address indexed from, uint256 indexed amount);

    error TakasurePool__NotZeroAddress();
    error TakasurePool__MustBeMoreThanZero();
    error TakaSurePool__BurnAmountExceedsBalance(uint256 balance, uint256 amountToBurn);

    constructor() ERC20("TAKASURE", "TAKA") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender); // TODO: Discuss. Who? The Dao?
        // Todo: Discuss. Allow someone here as Minter and Burner?
    }

    /// @notice Mint Taka tokens
    /// @dev It calls the mint function from the TakaToken contract
    /// @dev Reverts if the mint function fails
    /// @param to The address to mint tokens to
    /// @param amountToMint The amount of tokens to mint
    function mint(
        address to,
        uint256 amountToMint
    ) external onlyRole(MINTER_ROLE) nonReentrant returns (bool) {
        if (to == address(0)) {
            revert TakasurePool__NotZeroAddress();
        }
        if (amountToMint <= 0) {
            revert TakasurePool__MustBeMoreThanZero();
        }

        userBalance[to] += amountToMint;

        _mint(to, amountToMint);

        emit TakaTokenMinted(to, amountToMint);

        return true;
    }

    /// @notice Burn Taka tokens
    /// @dev It calls the burn function from the TakaToken contract
    /// @param amountToBurn The amount of tokens to burn
    function burn(uint256 amountToBurn) public override onlyRole(BURNER_ROLE) nonReentrant {
        if (amountToBurn <= 0) {
            revert TakasurePool__MustBeMoreThanZero();
        }

        uint256 balance = balanceOf(msg.sender);
        if (amountToBurn > balance) {
            revert TakaSurePool__BurnAmountExceedsBalance(balance, amountToBurn);
        }

        userBalance[msg.sender] -= amountToBurn;

        emit TakaTokenBurned(msg.sender, amountToBurn);

        super.burn(amountToBurn);
    }

    /// @notice Get the amount of minted tokens by a user
    /// @param user The address of the user
    function getMintedTokensByUser(address user) external view returns (uint256) {
        return userBalance[user];
    }
}
