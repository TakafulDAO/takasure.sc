// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";

/**
 * @dev Stateful fuzz handler for SFVault invariants.
 *      - Caps action sizes to keep runs realistic and avoid uint256 overflows.
 *      - Swallows reverts so the run continues and invariants can be checked.
 *      - Tracks if any share transfer unexpectedly succeeds.
 */
contract SFVaultHandler is Test {
    SFVault public immutable vault;
    IERC20 public immutable asset;
    AddressManager public immutable addrMgr;

    address public immutable operator;

    uint256 internal constant N_ACTORS = 10;

    // Keep numbers in a realistic USDC range (asset decimals are 6 in your setup).
    uint256 internal constant MAX_ASSETS_ACTION = 10_000_000 * 1e6; // 10m USDC
    uint256 internal constant MAX_SHARES_ACTION = 10_000_000 * 1e6; // 10m shares (same decimals as asset in OZ ERC4626 default)

    address[] internal actors;

    bool public transferSucceeded;

    constructor(SFVault _vault, IERC20 _asset, AddressManager _addrMgr, address _operator) {
        vault = _vault;
        asset = _asset;
        addrMgr = _addrMgr;
        operator = _operator;

        for (uint256 i = 0; i < N_ACTORS; i++) {
            address a = address(uint160(uint256(keccak256(abi.encodePacked("SFVaultActor", i)))));
            actors.push(a);
        }
    }

    function getActors() external view returns (address[] memory) {
        return actors;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % N_ACTORS];
    }

    /*//////////////////////////////////////////////////////////////
                            USER ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 actorSeed, uint256 assetsIn) external {
        address user = _actor(actorSeed);

        uint256 assetsToDeposit = bound(assetsIn, 0, MAX_ASSETS_ACTION);
        if (assetsToDeposit == 0) return;

        // exact balance (no addition => no overflow)
        deal(address(asset), user, assetsToDeposit);

        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);

        // swallow any vault revert
        try vault.deposit(assetsToDeposit, user) returns (uint256) {} catch {}

        vm.stopPrank();
    }

    function mint(uint256 actorSeed, uint256 sharesIn) external {
        address user = _actor(actorSeed);

        uint256 sharesToMint = bound(sharesIn, 0, MAX_SHARES_ACTION);
        if (sharesToMint == 0) return;

        uint256 neededAssets;
        try vault.previewMint(sharesToMint) returns (uint256 a) {
            neededAssets = a;
        } catch {
            return; // swallow view revert
        }

        if (neededAssets == 0 || neededAssets > MAX_ASSETS_ACTION) return;

        deal(address(asset), user, neededAssets);

        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);

        try vault.mint(sharesToMint, user) returns (uint256) {} catch {}

        vm.stopPrank();
    }

    function redeem(uint256 actorSeed, uint256 sharesIn) external {
        address user = _actor(actorSeed);

        uint256 balShares = vault.balanceOf(user);
        if (balShares == 0) return;

        uint256 sharesToRedeem = bound(sharesIn, 1, balShares);

        vm.startPrank(user);
        try vault.redeem(sharesToRedeem, user, user) returns (uint256) {} catch {}
        vm.stopPrank();
    }

    function withdraw(uint256 actorSeed, uint256 assetsIn) external {
        address user = _actor(actorSeed);

        uint256 maxAssets = vault.maxWithdraw(user);
        if (maxAssets == 0) return;

        if (maxAssets > MAX_ASSETS_ACTION) maxAssets = MAX_ASSETS_ACTION;

        uint256 assetsToWithdraw = bound(assetsIn, 1, maxAssets);

        vm.startPrank(user);
        try vault.withdraw(assetsToWithdraw, user, user) returns (uint256) {} catch {}
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                        TRANSFER ATTEMPTS (SHARES)
    //////////////////////////////////////////////////////////////*/

    function tryTransfer(uint256 fromSeed, uint256 toSeed, uint256 amtIn) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        if (from == to) return;

        uint256 balShares = vault.balanceOf(from);
        if (balShares == 0) return;

        uint256 amount = bound(amtIn, 1, balShares);

        vm.startPrank(from);
        (bool ok,) = address(vault).call(abi.encodeWithSelector(vault.transfer.selector, to, amount));
        vm.stopPrank();

        if (ok) transferSucceeded = true;
    }

    function tryTransferFrom(uint256 ownerSeed, uint256 toSeed, uint256 amtIn) external {
        address owner = _actor(ownerSeed);
        address to = _actor(toSeed);
        if (owner == to) return;

        uint256 balShares = vault.balanceOf(owner);
        if (balShares == 0) return;

        uint256 amount = bound(amtIn, 1, balShares);

        // Ensure allowance isn't the reason for failure; we want to hit _update.
        vm.startPrank(owner);
        vault.approve(owner, type(uint256).max);

        (bool ok,) = address(vault).call(abi.encodeWithSelector(vault.transferFrom.selector, owner, to, amount));
        vm.stopPrank();

        if (ok) transferSucceeded = true;
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT/OPERATOR ACTIONS
    //////////////////////////////////////////////////////////////*/

    function opSetFeeConfig(uint16 mgmtIn, uint16 perfIn, uint16 hurdleIn) external {
        // Match SFVault validation:
        // mgmt < 10000; perf <= 10000; hurdle <= 10000
        uint16 mgmt = uint16(bound(uint256(mgmtIn), 0, 9999));
        uint16 perf = uint16(bound(uint256(perfIn), 0, 10000));
        uint16 hurdle = uint16(bound(uint256(hurdleIn), 0, 10000));

        vm.prank(operator);
        (bool ok,) = address(vault).call(abi.encodeWithSelector(vault.setFeeConfig.selector, mgmt, perf, hurdle));
        ok;
    }

    function opSetTVLCap(uint256 capIn) external {
        // Allow 0 (uncapped) to hit that branch, but keep caps realistic otherwise.
        uint256 cap = bound(capIn, 0, MAX_ASSETS_ACTION);
        vm.prank(operator);
        (bool ok,) = address(vault).call(abi.encodeWithSelector(vault.setTVLCap.selector, cap));
        ok;
    }

    function opTakeFees(uint32 forwardSeconds) external {
        uint256 dt = bound(uint256(forwardSeconds), 0, 30 days);
        vm.warp(block.timestamp + dt);

        vm.prank(operator);
        (bool ok,) = address(vault).call(abi.encodeWithSelector(vault.takeFees.selector));
        ok; // can revert on InsufficientUSDCForFees; that's fine
    }

    function opTakeFeesTwiceSameTimestamp() external {
        vm.prank(operator);
        (bool ok1,) = address(vault).call(abi.encodeWithSelector(vault.takeFees.selector));
        ok1;

        // no warp -> elapsed == 0 path
        vm.prank(operator);
        (bool ok2,) = address(vault).call(abi.encodeWithSelector(vault.takeFees.selector));
        ok2;
    }

    function donateToVault(uint256 amountIn) external {
        uint256 amount = bound(amountIn, 0, MAX_ASSETS_ACTION);
        if (amount == 0) return;

        uint256 cur = asset.balanceOf(address(vault));
        deal(address(asset), address(vault), cur + amount);
    }

    function toggleMockFeeRecipientZero(bool enable) external {
        if (enable) {
            vm.mockCall(
                address(addrMgr),
                abi.encodeWithSignature("getProtocolAddressByName(string)", "SF_VAULT_FEE_RECIPIENT"),
                abi.encode(address(0), uint8(0), false)
            );
        } else {
            vm.clearMockedCalls();
        }
    }

    // Skip this file from coverage
    function test() public {}
}
