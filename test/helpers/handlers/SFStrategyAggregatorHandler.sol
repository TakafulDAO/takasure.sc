// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {TestAggSubStrategy} from "test/mocks/MockSFStrategy.sol";

contract SFStrategyAggregatorHandler is Test {
    using SafeERC20 for IERC20;

    SFStrategyAggregator public immutable aggregator;
    IERC20 public immutable asset;

    address public immutable vault; // caller required for deposit/withdraw
    address public immutable operator; // OPERATOR for management functions
    address public immutable pauser; // PAUSE_GUARDIAN for pause/unpause

    uint256 internal constant N_ACTORS = 8;
    uint256 internal constant N_STRATS = 6;

    // Keep amounts sane (USDC 6 decimals)
    uint256 internal constant MAX_ASSETS = 10_000_000 * 1e6; // 10m

    address[] internal actors;
    address[] internal strats;

    constructor(SFStrategyAggregator _aggregator, IERC20 _asset, address _vault, address _operator, address _pauser) {
        aggregator = _aggregator;
        asset = _asset;
        vault = _vault;
        operator = _operator;
        pauser = _pauser;

        for (uint256 i; i < N_ACTORS; i++) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked("AggActor", i)))));
            actors.push(a);
        }

        for (uint256 j; j < N_STRATS; j++) {
            TestAggSubStrategy s = new TestAggSubStrategy(_asset);
            strats.push(address(s));
        }
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function getStrats() external view returns (address[] memory) {
        return strats;
    }

    function _emptyPerStrategyData() internal pure returns (bytes memory) {
        return abi.encode(new address[](0), new bytes[](0));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % N_ACTORS];
    }

    function _strat(uint256 seed) internal view returns (address) {
        return strats[seed % N_STRATS];
    }

    /*//////////////////////////////////////////////////////////////
                            OPERATOR ACTIONS
    //////////////////////////////////////////////////////////////*/

    function opSetConfig(bytes calldata cfg) external {
        vm.prank(operator);
        (bool ok,) = address(aggregator).call(abi.encodeWithSelector(aggregator.setConfig.selector, cfg));
        ok;
    }

    function opAddSubStrategy(uint256 stratSeed, uint16 weightIn) external {
        address s = _strat(stratSeed);
        uint16 w = uint16(bound(uint256(weightIn), 0, 10_000));

        vm.prank(operator);
        (bool ok,) = address(aggregator).call(abi.encodeWithSelector(aggregator.addSubStrategy.selector, s, w));
        ok;
    }

    function opUpdateSubStrategy(uint256 stratSeed, uint16 weightIn, bool active) external {
        address s = _strat(stratSeed);
        uint16 w = uint16(bound(uint256(weightIn), 0, 10_000));

        vm.prank(operator);
        (bool ok,) =
            address(aggregator).call(abi.encodeWithSelector(aggregator.updateSubStrategy.selector, s, w, active));
        ok;
    }

    function opEmergencyExit(uint256 recvSeed) external {
        address receiver = _actor(recvSeed);

        vm.prank(operator);
        (bool ok,) = address(aggregator).call(abi.encodeWithSelector(aggregator.emergencyExit.selector, receiver));
        ok;
    }

    function opHarvest(bytes calldata data) external {
        vm.prank(operator);
        (bool ok,) = address(aggregator).call(abi.encodeWithSelector(aggregator.harvest.selector, data));
        ok;
    }

    function opRebalance(bytes calldata data) external {
        vm.prank(operator);
        (bool ok,) = address(aggregator).call(abi.encodeWithSelector(aggregator.rebalance.selector, data));
        ok;
    }

    /*//////////////////////////////////////////////////////////////
                           PAUSE ACTIONS
    //////////////////////////////////////////////////////////////*/

    function opPause() external {
        vm.prank(pauser);
        (bool ok,) = address(aggregator).call(abi.encodeWithSelector(aggregator.pause.selector));
        ok;
    }

    function opUnpause() external {
        vm.prank(pauser);
        (bool ok,) = address(aggregator).call(abi.encodeWithSelector(aggregator.unpause.selector));
        ok;
    }

    /*//////////////////////////////////////////////////////////////
                          VAULT-ONLY ACTIONS
    //////////////////////////////////////////////////////////////*/

    function vaultDeposit(uint256 assetsIn) external {
        uint256 amount = bound(assetsIn, 0, MAX_ASSETS);
        if (amount == 0) return;

        // fund aggregator (additive) and revert-safe: if the call fails, restore previous balance
        uint256 beforeBal = asset.balanceOf(address(aggregator));
        deal(address(asset), address(aggregator), beforeBal + amount);

        bytes memory data = _emptyPerStrategyData();

        vm.prank(vault);
        (bool ok,) = address(aggregator).call(abi.encodeWithSelector(aggregator.deposit.selector, amount, data));

        if (!ok) {
            // ensure we don't leave stray idle funds if deposit reverted (paused, etc.)
            deal(address(asset), address(aggregator), beforeBal);
        }
    }

    function vaultWithdraw(uint256 assetsIn, uint256 recvSeed) external {
        uint256 amount = bound(assetsIn, 0, MAX_ASSETS);
        if (amount == 0) return;

        address receiver = _actor(recvSeed);

        bytes memory data = _emptyPerStrategyData();

        vm.prank(vault);
        (bool ok,) =
            address(aggregator).call(abi.encodeWithSelector(aggregator.withdraw.selector, amount, receiver, data));
        ok; // may revert if paused/insufficient, swallowed
    }

    /*//////////////////////////////////////////////////////////////
                        STATE PERTURBATIONS
    //////////////////////////////////////////////////////////////*/

    function seedStrategyBalance(uint256 stratSeed, uint256 amountIn) external {
        // Put assets directly into a strategy (simulates accrued yield).
        uint256 amount = bound(amountIn, 0, MAX_ASSETS);
        if (amount == 0) return;

        address s = _strat(stratSeed);
        deal(address(asset), s, amount);
    }

    function tweakStrategyWithdrawBehavior(uint256 stratSeed, bool zeroWithdraw, uint256 forcedMax) external {
        address s = _strat(stratSeed);
        TestAggSubStrategy ts = TestAggSubStrategy(s);

        // Best-effort; these are external calls and should not revert.
        ts.setReturnZeroOnWithdraw(zeroWithdraw);

        // keep forced max sane
        uint256 fm = bound(forcedMax, 0, MAX_ASSETS);
        ts.setForcedMaxWithdraw(fm);
    }

    function test() external {}
}
