// SPDX-License-Identifier: GPL-3.0
/*
Detailed explanation of the flow tested here

This stateful invariant suite ports the main scenario from E2ETest to fuzzing with
a handler while reusing already deployed Save Funds contracts on Arbitrum One.

Flow:
1. Fork Arbitrum at a fixed block and load deployed contracts from
   deployments/mainnet_arbitrum_one.
2. Resolve live role holders from AddressManager and unpause protocol components
   when pause guardian is available.
3. Create users/swappers, fund them, register users, and set token approvals.
4. Configure SaveFundHandler with deployed vault/aggregator/strategy and live actors.
5. Fuzz state transitions (deposit/redeem/invest/withdraw-from-strategy/harvest/rebalance/
   buffer-policy/take-fees/pause toggles/transfer-attack attempts).
6. Continuously enforce invariants equivalent to the E2E assertions, adapted for
   pre-existing mainnet state at fork time.
*/
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {SFVault} from "contracts/saveFunds/protocol/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/protocol/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {SaveFundHandler} from "test/helpers/handlers/SaveFundHandler.sol";

contract SaveFundInvariantTest is StdInvariant, Test {
    uint256 internal constant FORK_BLOCK = 430826360;
    address internal constant UNI_UNIVERSAL_ROUTER = 0xA51afAFe0263b40EdaEf0Df8781eA9aa03E381a3;

    uint256 internal constant DUST_USDC = 10_000; // 0.01 USDC
    uint256 internal constant DUST_USDT = 10_000; // 0.01 USDT
    int24 internal constant REBALANCE_HALF_RANGE_TICKS = 1200;

    AddressManager internal addrMgr;
    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFUniswapV3Strategy internal uniV3;
    SaveFundHandler internal handler;
    AddressGetter internal addrGetter;

    IERC20 internal usdc;
    IERC20 internal usdt;

    address internal operator;
    address internal backendAdmin;
    address internal keeper;
    address internal pauseGuardian;

    address[] internal users;
    address[] internal swappers;

    uint256 internal initialTotalSupply;
    uint256 internal initialStrategyUsdc;

    function setUp() public {
        uint256 forkId = vm.createFork(vm.envString("ARBITRUM_MAINNET_RPC_URL"), FORK_BLOCK);
        vm.selectFork(forkId);

        addrGetter = new AddressGetter();
        addrMgr = AddressManager(_getAddr("AddressManager"));
        vault = SFVault(_getAddr("SFVault"));
        aggregator = SFStrategyAggregator(_getAddr("SFStrategyAggregator"));
        uniV3 = SFUniswapV3Strategy(_getAddr("SFUniswapV3Strategy"));

        operator = addrMgr.currentRoleHolders(Roles.OPERATOR);
        backendAdmin = addrMgr.currentRoleHolders(Roles.BACKEND_ADMIN);
        keeper = addrMgr.currentRoleHolders(Roles.KEEPER);
        pauseGuardian = addrMgr.currentRoleHolders(Roles.PAUSE_GUARDIAN);
        if (keeper == address(0)) keeper = operator;

        require(operator != address(0) && addrMgr.hasRole(Roles.OPERATOR, operator), "operator missing");
        require(backendAdmin != address(0) && addrMgr.hasRole(Roles.BACKEND_ADMIN, backendAdmin), "backend admin missing");
        require(keeper != address(0) && addrMgr.hasRole(Roles.KEEPER, keeper), "keeper missing");

        if (pauseGuardian != address(0) && addrMgr.hasRole(Roles.PAUSE_GUARDIAN, pauseGuardian)) {
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

        assertEq(addrMgr.getProtocolAddressByName("PROTOCOL__SF_VAULT").addr, address(vault));
        assertEq(addrMgr.getProtocolAddressByName("PROTOCOL__SF_AGGREGATOR").addr, address(aggregator));

        usdc = IERC20(vault.asset());
        usdt = uniV3.otherToken();

        _createActorsAndApprovals();
        _registerAllUsers();

        handler = new SaveFundHandler();
        handler.configureProtocol(vault, aggregator, uniV3);
        handler.configureActors(operator, keeper, backendAdmin, pauseGuardian);
        handler.configureScenario(REBALANCE_HALF_RANGE_TICKS, DUST_USDC, DUST_USDT);
        handler.setUsers(users);
        handler.setSwappers(swappers);
        _approveMarketForSwappers();

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.backend_registerMember.selector;
        selectors[1] = handler.user_deposit.selector;
        selectors[2] = handler.user_redeem.selector;
        selectors[3] = handler.keeper_invest.selector;
        selectors[4] = handler.keeper_withdrawFromStrategy.selector;
        selectors[5] = handler.keeper_harvest.selector;
        selectors[6] = handler.keeper_rebalance.selector;
        selectors[7] = handler.keeper_applyBufferPolicy.selector;
        selectors[8] = handler.operator_takeFees.selector;
        selectors[9] = handler.pauser_togglePause.selector;
        selectors[10] = handler.attacker_tryTransferFrom.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

        initialTotalSupply = vault.totalSupply();
        initialStrategyUsdc = usdc.balanceOf(address(uniV3));
    }

    function invariant_all() public view {
        _assertShareSupplyEqualsBaselinePlusFuzzUsers();
        _assertStrategyCustodyDriftWithinDustBound();
        _assertNoStaleRouterApprovals();
        _assertUserClaimableNeverExceedsVaultAssets();
    }

    function _assertShareSupplyEqualsBaselinePlusFuzzUsers() internal view {
        uint256 sum;
        for (uint256 i; i < users.length; ++i) {
            sum += vault.balanceOf(users[i]);
        }
        assertEq(vault.totalSupply(), initialTotalSupply + sum, "share supply mismatch");
    }

    function _assertStrategyCustodyDriftWithinDustBound() internal view {
        assertLe(usdc.balanceOf(address(uniV3)), initialStrategyUsdc + DUST_USDC, "uniV3 holds too much USDC");
    }

    function _assertNoStaleRouterApprovals() internal view {
        assertEq(usdc.allowance(address(uniV3), UNI_UNIVERSAL_ROUTER), 0, "USDC router allowance not cleared");
        assertEq(usdt.allowance(address(uniV3), UNI_UNIVERSAL_ROUTER), 0, "USDT router allowance not cleared");
    }

    function _assertUserClaimableNeverExceedsVaultAssets() internal view {
        uint256 sumClaimable;
        for (uint256 i; i < users.length; ++i) {
            uint256 sh = vault.balanceOf(users[i]);
            if (sh == 0) continue;
            sumClaimable += vault.previewRedeem(sh);
        }
        assertLe(sumClaimable, vault.totalAssets() + 10, "sum claimable > totalAssets");
    }

    function _getAddr(string memory contractName) internal view returns (address) {
        return addrGetter.getAddress(block.chainid, contractName);
    }

    function _createActorsAndApprovals() internal {
        uint256 nUsers = 16;
        uint256 nSwappers = 16;

        users = new address[](nUsers);
        swappers = new address[](nSwappers);

        for (uint256 i; i < nUsers; ++i) {
            address u = makeAddr(string.concat("invUser", vm.toString(i)));
            users[i] = u;
            deal(address(usdc), u, 1_000_000e6);

            vm.startPrank(u);
            usdc.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }

        for (uint256 j; j < nSwappers; ++j) {
            address s = makeAddr(string.concat("invSwapper", vm.toString(j)));
            swappers[j] = s;
            deal(address(usdc), s, 5_000_000e6);
            deal(address(usdt), s, 5_000_000e6);
        }
    }

    function _registerAllUsers() internal {
        vm.startPrank(backendAdmin);
        for (uint256 i; i < users.length; ++i) {
            vault.registerMember(users[i]);
        }
        vm.stopPrank();
    }

    function _approveMarketForSwappers() internal {
        address market = address(handler.market());
        for (uint256 i; i < swappers.length; ++i) {
            address s = swappers[i];
            vm.startPrank(s);
            usdc.approve(market, type(uint256).max);
            usdt.approve(market, type(uint256).max);
            vm.stopPrank();
        }
    }
}

contract AddressGetter is GetContractAddress {
    function getAddress(uint256 chainId, string memory contractName) external view returns (address) {
        return _getContractAddress(chainId, contractName);
    }
}
