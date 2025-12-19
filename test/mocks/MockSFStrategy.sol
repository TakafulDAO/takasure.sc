// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Simple mock strategy to test `strategyAssets()` and `totalAssets()`.
contract MockSFStrategy is ISFStrategy {
    address public immutable override vault;
    address public immutable override asset;

    uint256 internal _totalAssets;
    uint256 internal _maxTVL;

    constructor(address _vault, address _asset) {
        vault = _vault;
        asset = _asset;
    }

    // --- view getters ---

    function totalAssets() external view override returns (uint256) {
        return _totalAssets;
    }

    function maxDeposit() external view override returns (uint256) {
        // for tests: unlimited unless maxTVL set
        if (_maxTVL == 0) return type(uint256).max;
        return _maxTVL - _totalAssets;
    }

    function maxWithdraw() external view override returns (uint256) {
        return _totalAssets;
    }

    // --- core hooks, dummy impls for compilation ---

    function deposit(uint256 assets, bytes calldata) external override returns (uint256 investedAssets) {
        // in tests we just simulate that all assets go into strategy
        _totalAssets += assets;
        return assets;
    }

    function withdraw(uint256 assets, address receiver, bytes calldata)
        external
        override
        returns (uint256 withdrawnAssets)
    {
        uint256 amount = assets > _totalAssets ? _totalAssets : assets;
        _totalAssets -= amount;

        if (receiver != address(0) && amount > 0) {
            // we don't actually need to transfer tokens in unit tests
            // (vault tests only care about the accounting via `totalAssets()`)
        }

        return amount;
    }

    // --- maintenance / admin (no-ops for tests) ---

    function pause() external override {}
    function unpause() external override {}
    function emergencyExit(address) external override {}

    function setMaxTVL(uint256 newMaxTVL) external override {
        _maxTVL = newMaxTVL;
    }
    function setConfig(bytes calldata) external {}

    function test() public {}
}

    contract TestAggSubStrategy {
        using SafeERC20 for IERC20;

        IERC20 public immutable underlying;
        uint256 public harvestCount;
        uint256 public rebalanceCount;

        bool public returnZeroOnWithdraw;
        bool public forceMaxWithdraw;
        uint256 public forcedMaxWithdraw;

        constructor(IERC20 _underlying) {
            underlying = _underlying;
        }

        function setReturnZeroOnWithdraw(bool v) external {
            returnZeroOnWithdraw = v;
        }

        function setForcedMaxWithdraw(uint256 v) external {
            forceMaxWithdraw = true;
            forcedMaxWithdraw = v;
        }

        // ISFStrategy-like
        function deposit(uint256 assets, bytes calldata) external returns (uint256 invested) {
            if (assets == 0) return 0;
            underlying.safeTransferFrom(msg.sender, address(this), assets);
            return assets;
        }

        function asset() external view returns (address) {
            return address(underlying);
        }

        function withdraw(uint256 assets, address receiver, bytes calldata) external returns (uint256 withdrawn) {
            if (assets == 0 || receiver == address(0) || returnZeroOnWithdraw) return 0;

            uint256 bal = underlying.balanceOf(address(this));
            uint256 toSend = assets > bal ? bal : assets;
            if (toSend == 0) return 0;

            underlying.safeTransfer(receiver, toSend);
            return toSend;
        }

        function totalAssets() external view returns (uint256) {
            return underlying.balanceOf(address(this));
        }

        function maxWithdraw() external view returns (uint256) {
            if (forceMaxWithdraw) return forcedMaxWithdraw;
            return underlying.balanceOf(address(this));
        }

        // maintenance-like
        function harvest(bytes calldata) external {
            harvestCount++;
        }

        function rebalance(bytes calldata) external {
            rebalanceCount++;
        }

        function test() external {}
    }

    contract TestSubStrategy {
        using SafeERC20 for IERC20;

        IERC20 public immutable underlying;

        uint256 public harvestCount;
        uint256 public rebalanceCount;

        bool public returnZeroOnWithdraw;
        bool public forceMaxWithdraw;
        uint256 public forcedMaxWithdraw;

        constructor(IERC20 _underlying) {
            underlying = _underlying;
        }

        function setReturnZeroOnWithdraw(bool v) external {
            returnZeroOnWithdraw = v;
        }

        function setForcedMaxWithdraw(uint256 v) external {
            forceMaxWithdraw = true;
            forcedMaxWithdraw = v;
        }

        // --- surface used by the aggregator ---

        function deposit(uint256 assets, bytes calldata) external returns (uint256 invested) {
            if (assets == 0) return 0;
            underlying.safeTransferFrom(msg.sender, address(this), assets);
            return assets;
        }

        function withdraw(uint256 assets, address receiver, bytes calldata) public virtual returns (uint256 withdrawn) {
            if (assets == 0 || receiver == address(0) || returnZeroOnWithdraw) return 0;

            uint256 bal = underlying.balanceOf(address(this));
            uint256 toSend = assets > bal ? bal : assets;
            if (toSend == 0) return 0;

            underlying.safeTransfer(receiver, toSend);
            return toSend;
        }

        function totalAssets() external view returns (uint256) {
            return underlying.balanceOf(address(this));
        }

        function asset() external view returns (address) {
            return address(underlying);
        }

        function maxWithdraw() external view returns (uint256) {
            if (forceMaxWithdraw) return forcedMaxWithdraw;
            return underlying.balanceOf(address(this));
        }

        // --- maintenance surface used by the aggregator ---

        function harvest(bytes calldata) external {
            harvestCount++;
        }

        function rebalance(bytes calldata) external {
            rebalanceCount++;
        }

        function test() public virtual {}
    }

    contract HalfWithdrawStrategy is TestSubStrategy {
        constructor(IERC20 _underlying) TestSubStrategy(_underlying) {}

        // Return only half of what would normally be withdrawn (to force "loss" branches)
        function withdraw(uint256 assets, address receiver, bytes calldata data)
            public
            override
            returns (uint256 withdrawn)
        {
            // ask parent to send up to `assets`, but we only want half of requested.
            // simplest: request half from the base implementation.
            uint256 halfReq = assets / 2;
            if (halfReq == 0) return 0;

            return super.withdraw(halfReq, receiver, data);
        }

        function test() public override {}
    }

    contract RecorderSubStrategy {
        using SafeERC20 for IERC20;

        IERC20 public immutable underlying;

        uint256 public harvestCount;
        uint256 public rebalanceCount;

        bytes32 public lastDepositDataHash;
        bytes32 public lastWithdrawDataHash;
        bytes32 public lastHarvestDataHash;
        bytes32 public lastRebalanceDataHash;

        constructor(IERC20 _underlying) {
            underlying = _underlying;
        }

        function asset() external view returns (address) {
            return address(underlying);
        }

        function deposit(uint256 assets, bytes calldata data) external returns (uint256) {
            lastDepositDataHash = keccak256(data);
            if (assets == 0) return 0;
            underlying.safeTransferFrom(msg.sender, address(this), assets);
            return assets;
        }

        function withdraw(uint256 assets, address receiver, bytes calldata data) external returns (uint256) {
            lastWithdrawDataHash = keccak256(data);

            uint256 bal = underlying.balanceOf(address(this));
            uint256 amt = assets > bal ? bal : assets;
            if (amt == 0) return 0;

            underlying.safeTransfer(receiver, amt);
            return amt;
        }

        function totalAssets() external view returns (uint256) {
            return underlying.balanceOf(address(this));
        }

        function maxWithdraw() external view returns (uint256) {
            return underlying.balanceOf(address(this));
        }

        function harvest(bytes calldata data) external {
            harvestCount++;
            lastHarvestDataHash = keccak256(data);
        }

        function rebalance(bytes calldata data) external {
            rebalanceCount++;
            lastRebalanceDataHash = keccak256(data);
        }
    }

    contract PartialPullSubStrategy {
        using SafeERC20 for IERC20;

        IERC20 public immutable underlying;

        constructor(IERC20 _underlying) {
            underlying = _underlying;
        }

        function asset() external view returns (address) {
            return address(underlying);
        }

        // Only pulls half the approved amount to trigger aggregator's "reset approval" branch.
        function deposit(uint256 assets, bytes calldata) external returns (uint256) {
            if (assets == 0) return 0;

            uint256 pull = assets / 2;
            if (pull == 0) pull = 1; // keep non-zero for very small fuzzed amounts

            underlying.safeTransferFrom(msg.sender, address(this), pull);
            return pull;
        }

        function withdraw(uint256 assets, address receiver, bytes calldata) external returns (uint256) {
            uint256 bal = underlying.balanceOf(address(this));
            uint256 amt = assets > bal ? bal : assets;
            if (amt == 0) return 0;

            underlying.safeTransfer(receiver, amt);
            return amt;
        }

        function totalAssets() external view returns (uint256) {
            return underlying.balanceOf(address(this));
        }

        function maxWithdraw() external view returns (uint256) {
            return underlying.balanceOf(address(this));
        }

        function harvest(bytes calldata) external {}
        function rebalance(bytes calldata) external {}
    }

    // Intentionally no asset() function so the staticcall in _assertChildStrategyCompatible fails.
    contract NoAssetStrategy {}

    contract WrongAssetStrategy {
        address internal immutable wrong;

        constructor(address wrong_) {
            wrong = wrong_;
        }

        function asset() external view returns (address) {
            return wrong;
        }
    }

    contract ShortReturnAssetStrategy {
        // Return a deliberately short returnData (len < 32) while "ok == true"
        function asset() external pure returns (address) {
            assembly {
                mstore(0x00, 0x00)
                return(0x00, 0x01)
            }
        }
    }
