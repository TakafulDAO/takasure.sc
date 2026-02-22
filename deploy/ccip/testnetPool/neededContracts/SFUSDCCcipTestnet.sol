// SPDX-License-Identifier: MIT

/**
 * @title SFUSDCCcipTestnet
 * @author Maikel Ordaz
 * @notice Testnet-only SFUSDC token with CCIP burn/mint compatibility.
 */

pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGetCCIPAdmin} from "ccip/contracts/src/v0.8/ccip/interfaces/IGetCCIPAdmin.sol";

contract SFUSDCCcipTestnet is ERC20, Ownable, IGetCCIPAdmin {
    mapping(address account => bool allowed) public isMinter;
    mapping(address account => bool allowed) public isBurner;

    address private s_ccipAdmin;

    event MintRoleGranted(address indexed account);
    event BurnRoleGranted(address indexed account);
    event MintRoleRevoked(address indexed account);
    event BurnRoleRevoked(address indexed account);
    event CCIPAdminSet(address indexed oldAdmin, address indexed newAdmin);

    error SFUSDCCcipTestnet__NotMinter(address account);
    error SFUSDCCcipTestnet__NotBurner(address account);
    error SFUSDCCcipTestnet__ZeroAddressNotAllowed();

    modifier onlyMinter() {
        if (!isMinter[msg.sender]) revert SFUSDCCcipTestnet__NotMinter(msg.sender);
        _;
    }

    modifier onlyBurner() {
        if (!isBurner[msg.sender]) revert SFUSDCCcipTestnet__NotBurner(msg.sender);
        _;
    }

    constructor(address _owner) ERC20("SFUSDC", "SFUSDC") Ownable(_owner) {
        isMinter[_owner] = true;
        isBurner[_owner] = true;
        s_ccipAdmin = _owner;

        emit MintRoleGranted(_owner);
        emit BurnRoleGranted(_owner);
        emit CCIPAdminSet(address(0), _owner);
    }

    function grantMintRole(address account) external onlyOwner {
        if (account == address(0)) revert SFUSDCCcipTestnet__ZeroAddressNotAllowed();
        if (!isMinter[account]) {
            isMinter[account] = true;
            emit MintRoleGranted(account);
        }
    }

    function grantBurnRole(address account) external onlyOwner {
        if (account == address(0)) revert SFUSDCCcipTestnet__ZeroAddressNotAllowed();
        if (!isBurner[account]) {
            isBurner[account] = true;
            emit BurnRoleGranted(account);
        }
    }

    function grantMintAndBurnRoles(address account) external onlyOwner {
        if (account == address(0)) revert SFUSDCCcipTestnet__ZeroAddressNotAllowed();

        if (!isMinter[account]) {
            isMinter[account] = true;
            emit MintRoleGranted(account);
        }

        if (!isBurner[account]) {
            isBurner[account] = true;
            emit BurnRoleGranted(account);
        }
    }

    function revokeMintRole(address account) external onlyOwner {
        if (isMinter[account]) {
            isMinter[account] = false;
            emit MintRoleRevoked(account);
        }
    }

    function revokeBurnRole(address account) external onlyOwner {
        if (isBurner[account]) {
            isBurner[account] = false;
            emit BurnRoleRevoked(account);
        }
    }

    /// @notice Faucet-like minting helper kept for team testing ergonomics.
    function mintUSDC(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @notice CCIP pool mint hook.
    function mint(address account, uint256 amount) external onlyMinter {
        _mint(account, amount);
    }

    /// @notice CCIP pool burn hook.
    function burn(uint256 amount) public onlyBurner {
        _burn(msg.sender, amount);
    }

    /// @notice Alternate burn signature used by some burn/mint token flows.
    function burn(address account, uint256 amount) public onlyBurner {
        _burn(account, amount);
    }

    /// @notice Alternate burnFrom signature used by some burn/mint token flows.
    function burnFrom(address account, uint256 amount) public onlyBurner {
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
    }

    /// @inheritdoc IGetCCIPAdmin
    function getCCIPAdmin() external view override returns (address) {
        return s_ccipAdmin;
    }

    function setCCIPAdmin(address newAdmin) external onlyOwner {
        address oldAdmin = s_ccipAdmin;
        s_ccipAdmin = newAdmin;
        emit CCIPAdminSet(oldAdmin, newAdmin);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
