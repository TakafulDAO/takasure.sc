// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";

import {RevShareModule} from "contracts/modules/RevShareModule.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

/// @notice Stateful-fuzz handler for RevShareModule invariants.
/// - Bounds inputs to avoid trivial reverts
/// - Ensures claims only happen when revenues are available *and* approvedDeposits can cover them
/// - Settles globals before emergencyWithdraw to keep storage accumulators monotone
contract RevShareModuleHandler is Test {
    RevShareModule public module;
    RevShareNFT public nft;
    IUSDC public usdc;
    AddressManager public addressManager;

    address public operator; // takadao (OPERATOR + REVENUE_CLAIMER)
    address public revenueReceiver; // address that actually receives 25% stream
    address public moduleCaller; // authorized "Module" for notifyNewRevenue

    // Wide pioneer set to reflect many holders
    address[] public pioneers;

    // Last-seen STORAGE accumulators (not the computed getters)
    uint256 public lastPerNftP;
    uint256 public lastPerNftT;

    constructor(
        RevShareModule _module,
        RevShareNFT _nft,
        IUSDC _usdc,
        AddressManager _am,
        address _operator,
        address _revenueReceiver,
        address _moduleCaller,
        address[] memory _pioneers
    ) {
        module = _module;
        nft = _nft;
        usdc = _usdc;
        addressManager = _am;
        operator = _operator;
        revenueReceiver = _revenueReceiver;
        moduleCaller = _moduleCaller;

        for (uint256 i = 0; i < _pioneers.length; i++) {
            pioneers.push(_pioneers[i]);
        }

        // Initialize baselines from STORAGE (public vars)
        lastPerNftP = module.revenuePerNftOwnedByPioneers();
        lastPerNftT = module.takadaoRevenueScaled();
    }

    /*//////////////////////////////////////////////////////////////
                             RANDOM ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Authorized module notifies new revenue.
    /// Amount is bounded to the moduleCaller’s current USDC balance.
    function op_notify(uint256 amt) external {
        uint256 bal = usdc.balanceOf(moduleCaller);
        if (bal == 0) return;

        // Ensure both 75% and 25% shares are non-zero after floor
        uint256 minAmt = 4; // micro-USDC → 3/1 split
        if (bal < minAmt) return;

        amt = bound(amt, minAmt, bal);

        vm.startPrank(moduleCaller);
        usdc.approve(address(module), amt);
        module.notifyNewRevenue(amt);
        vm.stopPrank();

        _pokeAccumulators();
    }

    /// @notice Random pioneer claims, only when:
    /// - address actually has NFTs
    /// - revenues are available (release if needed)
    /// - approvedDeposits is sufficient to fully cover the `earned` amount
    function op_claimPioneer(uint256 idx) external {
        if (pioneers.length == 0) return;
        idx = bound(idx, 0, pioneers.length - 1);
        address p = pioneers[idx];
        if (nft.balanceOf(p) == 0) return; // must be a pioneer

        _ensureAvailable();

        uint256 earned = module.earnedByPioneers(p);
        if (earned == 0) return;

        uint256 approved = module.approvedDeposits();
        if (earned > approved) return; // would revert inside module; skip in handler

        vm.prank(p);
        module.claimRevenueShare(); // now safe

        _pokeAccumulators();
    }

    /// @notice Operator (REVENUE_CLAIMER) triggers claim for 25% stream to revenueReceiver.
    /// Requires RR to hold NFTs and `approvedDeposits` to cover the full `earned`.
    function op_claimTakadao() external {
        _ensureAvailable();

        uint256 earned = module.earnedByTakadao(revenueReceiver);
        if (earned == 0) return;

        uint256 approved = module.approvedDeposits();
        if (earned > approved) return; // would revert inside module; skip in handler

        vm.prank(operator);
        module.claimRevenueShare();

        _pokeAccumulators();
    }

    /// @notice Sweep extra funds (balance - approvedDeposits) to the operator.
    function op_sweep() external {
        uint256 bal = usdc.balanceOf(address(module));
        uint256 approved = module.approvedDeposits();
        if (bal > approved) {
            vm.prank(operator);
            module.sweepNonApprovedDeposits();
        }
        _pokeAccumulators();
    }

    /// @notice Set an available date into the near future to exercise releaseRevenues().
    function op_setAvailableDate(uint256 secsAhead) external {
        secsAhead = bound(secsAhead, 1, 30 days);
        vm.prank(operator);
        module.setAvailableDate(block.timestamp + secsAhead);
        _pokeAccumulators();
    }

    /// @notice Release revenues early if the available date is in the future.
    function op_release() external {
        if (block.timestamp < module.revenuesAvailableDate()) {
            vm.prank(operator);
            module.releaseRevenues();
        }
        _pokeAccumulators();
    }

    /// @notice Set rewards duration only when no active stream.
    function op_setRewardsDuration(uint256 newDur) external {
        if (block.timestamp < module.periodFinish()) return; // no mid-stream change
        newDur = bound(newDur, 1 days, 400 days);
        vm.prank(operator);
        module.setRewardsDuration(newDur);
        _pokeAccumulators();
    }

    /// @notice Emergency withdraw:
    /// - Settle global accumulators first so STORAGE remains monotone
    /// - Then reset rates/period & flush tokens to operator
    function op_emergency() external {
        module.updateRevenue(address(0)); // settle globals before resetting lastUpdateTime
        vm.prank(operator);
        module.emergencyWithdraw();
        _pokeAccumulators();
    }

    /// @notice Random time warp within a week.
    function op_warp(uint256 secs) external {
        secs = bound(secs, 1, 7 days);
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + 1);
        _pokeAccumulators();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Capture latest STORAGE accumulators as the baseline.
    function _pokeAccumulators() internal {
        uint256 pStored = module.revenuePerNftOwnedByPioneers();
        uint256 tStored = module.takadaoRevenueScaled();
        if (pStored > lastPerNftP) lastPerNftP = pStored;
        if (tStored > lastPerNftT) lastPerNftT = tStored;
    }

    /// @dev Ensure revenues are available; if not, operator releases them.
    function _ensureAvailable() internal {
        uint256 avail = module.revenuesAvailableDate();
        if (block.timestamp < avail) {
            vm.prank(operator);
            module.releaseRevenues();
        }
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
