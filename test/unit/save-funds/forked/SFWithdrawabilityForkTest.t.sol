// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFVault} from "contracts/saveFunds/protocol/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/protocol/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SFWithdrawabilityForkTest is Test {
    uint256 internal constant HISTORICAL_BLOCK = 445958309; // Still failing here
    uint256 internal constant FIX_DEPLOYED_BLOCK = 446007905;
    uint256 internal constant WITHDRAW_AMOUNT = 50e6;
    uint256 internal constant EXPECTED_HISTORICAL_AGG_WITHDRAW = 49_991_829;
    address internal constant USER = 0xf2F766c362A784B5DCeC02A0B6F5fAb6ceE4f32A;

    ForkAddressGetter internal addrGetter;

    AddressManager internal addrMgr;
    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFUniswapV3Strategy internal uniV3;
    IERC20 internal asset;

    address internal operator;
    address internal pauseGuardian;

    function testForkHistorical_CharacterizesWithdrawMismatch_AtBlock445958309() public {
        _selectFork(HISTORICAL_BLOCK);

        assertGe(vault.maxWithdraw(USER), WITHDRAW_AMOUNT);
        assertEq(vault.idleAssets(), 0);

        vm.prank(address(vault));
        uint256 got = aggregator.withdraw(WITHDRAW_AMOUNT, address(vault), bytes(""));

        assertEq(got, EXPECTED_HISTORICAL_AGG_WITHDRAW);
    }

    function testForkHistorical_UserWithdrawReverts_AtBlock445958309() public {
        _selectFork(HISTORICAL_BLOCK);

        vm.prank(USER);
        vm.expectRevert(SFVault.SFVault__InsufficientIdleAssets.selector);
        vault.withdraw(WITHDRAW_AMOUNT, USER, USER);
    }

    function testForkLatest_AtBlock446007905_UserCanWithdraw50Usdc() public {
        _selectFork(FIX_DEPLOYED_BLOCK);

        assertGe(vault.maxWithdraw(USER), WITHDRAW_AMOUNT);
        assertGe(aggregator.previewWithdrawable(bytes("")), WITHDRAW_AMOUNT);

        uint256 userBalanceBefore = asset.balanceOf(USER);

        vm.prank(USER);
        vault.withdraw(WITHDRAW_AMOUNT, USER, USER);

        uint256 userBalanceAfter = asset.balanceOf(USER);

        assertEq(userBalanceAfter, userBalanceBefore + WITHDRAW_AMOUNT);
    }
    function _selectFork(uint256 blockNumber) internal {
        uint256 forkId = vm.createFork(vm.envString("ARBITRUM_MAINNET_RPC_URL"), blockNumber);
        vm.selectFork(forkId);
        _loadForkContracts();
    }

    function _loadForkContracts() internal {
        addrGetter = new ForkAddressGetter();

        addrMgr = AddressManager(_getAddr("AddressManager"));
        vault = SFVault(_getAddr("SFVault"));
        aggregator = SFStrategyAggregator(_getAddr("SFStrategyAggregator"));
        uniV3 = SFUniswapV3Strategy(_getAddr("SFUniswapV3Strategy"));
        asset = IERC20(vault.asset());

        operator = addrMgr.currentRoleHolders(Roles.OPERATOR);
        pauseGuardian = addrMgr.currentRoleHolders(Roles.PAUSE_GUARDIAN);

        require(operator != address(0) && addrMgr.hasRole(Roles.OPERATOR, operator), "operator missing");

        _ensureUnpaused();
    }

    function _ensureUnpaused() internal {
        if (pauseGuardian == address(0) || !addrMgr.hasRole(Roles.PAUSE_GUARDIAN, pauseGuardian)) return;

        if (vault.paused()) {
            vm.prank(pauseGuardian);
            vault.unpause();
        }

        if (aggregator.paused()) {
            vm.prank(pauseGuardian);
            aggregator.unpause();
        }

        if (uniV3.paused()) {
            vm.prank(pauseGuardian);
            uniV3.unpause();
        }
    }
    function _getAddr(string memory contractName) internal view returns (address) {
        return addrGetter.getAddress(block.chainid, contractName);
    }
}

contract ForkAddressGetter is GetContractAddress {
    function getAddress(uint256 chainId, string memory contractName) external view returns (address) {
        return _getContractAddress(chainId, contractName);
    }
}
