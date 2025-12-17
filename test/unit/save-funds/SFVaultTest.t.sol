// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFVault} from "test/utils/05-DeploySFVault.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {MockSFStrategy} from "test/mocks/MockSFStrategy.sol";

import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";

contract SFVaultTest is Test {
    DeployManagers managersDeployer;
    DeploySFVault vaultDeployer;
    AddAddressesAndRoles addressesAndRoles;

    SFVault vault;
    AddressManager addrMgr;
    ModuleManager modMgr;

    IERC20 asset;
    address takadao;
    address feeRecipient;

    uint256 private constant MAX_BPS = 10_000; // 100% in basis points

    function setUp() public {
        managersDeployer = new DeployManagers();
        vaultDeployer = new DeploySFVault();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();
        (address operatorAddr,,,,,,) = addressesAndRoles.run(_addrMgr, config, address(_modMgr));

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        takadao = operatorAddr;

        (vault) = vaultDeployer.run(addrMgr);

        // Configure fee recipient in AddressManager
        feeRecipient = makeAddr("feeRecipient");
        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("SF_VAULT_FEE_RECIPIENT", feeRecipient, ProtocolAddressType.Admin);

        asset = IERC20(vault.asset());
    }

    /*//////////////////////////////////////////////////////////////
                        BASIC / INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function testSFVault_InitialConfig() public {
        // basic invariants
        assertTrue(address(vault.asset()) != address(0));
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.idleAssets(), 0);
        assertEq(vault.strategyAssets(), 0);
        assertEq(vault.totalSupply(), 0);

        // fees off by default
        assertEq(vault.managementFeeBPS(), 0);
        assertEq(vault.performanceFeeBPS(), 0);
        assertEq(vault.performanceFeeHurdleBPS(), 0);

        // some TVL cap exists (we don't assert exact value)
        assertGe(vault.TVLCap(), 0);

        // no attached strategy on deploy
        assertEq(address(vault.strategy()), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                              CAPS LOGIC
    //////////////////////////////////////////////////////////////*/

    function testSFVault_SetTVLCap_UpdatesState() public {
        uint256 oldCap = vault.TVLCap();
        uint256 newCap = oldCap + 1_000_000;

        vm.prank(takadao);
        vault.setTVLCap(newCap);

        assertEq(vault.TVLCap(), newCap);
    }

    function testSFVault_MaxDeposit_RespectsTVLCap() public {
        address user = address(this);
        uint256 cap = 1_000_000;

        // set a clean TVL cap
        vm.prank(takadao);
        vault.setTVLCap(cap);

        // no assets in vault yet, user can deposit up to cap
        uint256 max0 = vault.maxDeposit(user);
        assertEq(max0, cap);

        // deposit half of the cap
        uint256 depositAmount = cap / 2;
        _prepareUser(user, depositAmount);
        vault.deposit(depositAmount, user);

        // now the remaining room should be cap - depositAmount
        uint256 max1 = vault.maxDeposit(user);
        assertEq(max1, cap - depositAmount);
    }

    function testSFVault_MaxDeposit_ZeroWhenCapReached() public {
        address user = address(this);
        uint256 cap = 500_000;

        vm.prank(takadao);
        vault.setTVLCap(cap);

        _prepareUser(user, cap);
        vault.deposit(cap, user);

        uint256 maxAfter = vault.maxDeposit(user);
        assertEq(maxAfter, 0);
    }

    function testSFVault_MaxDeposit_UncappedWhenTVLCapZero() public {
        address user = address(this);

        // convention: TVLCap == 0 means "no global cap"
        vm.prank(takadao);
        vault.setTVLCap(0);

        uint256 maxDep = vault.maxDeposit(user);
        assertEq(maxDep, type(uint256).max);
    }

    function testSFVault_Deposit_RevertsWhenExceedsMaxDeposit() public {
        address user = address(this);
        uint256 cap = 200_000;

        vm.prank(takadao);
        vault.setTVLCap(cap);

        uint256 tooMuch = cap + 1;

        deal(address(asset), user, tooMuch);
        vm.startPrank(user);
        asset.approve(address(vault), tooMuch);

        vm.expectRevert();
        vault.deposit(tooMuch, user);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                          MANAGEMENT FEE / DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function _prepareUser(address user, uint256 amount) internal {
        deal(address(asset), user, amount);
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
    }

    function testSFVault_PreviewDeposit_NoManagementFee() public {
        uint256 amount = 1_000_000;

        // default managementFeeBPS == 0
        uint256 preview = vault.previewDeposit(amount);

        // For empty ERC4626 vault, shares == assets
        assertEq(preview, amount);
    }

    function testSFVault_PreviewDeposit_WithManagementFee() public {
        uint256 amount = 1_000_000;
        uint16 mgmtBPS = 200; // 2%

        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        uint256 preview = vault.previewDeposit(amount);
        uint256 grossShares = amount;
        uint256 expectedFeeShares = (grossShares * mgmtBPS) / MAX_BPS;
        uint256 expectedUserShares = grossShares - expectedFeeShares;

        assertEq(preview, expectedUserShares);
    }

    // function testSFVault_Deposit_MintsSharesAndTakesManagementFee() public {
    //     address user = address(this);
    //     uint256 amount = 1_000_000;
    //     uint16 mgmtBPS = 500; // 5%

    //     vm.prank(takadao);
    //     vault.setFeeConfig(mgmtBPS, 0, 0);

    //     _prepareUser(user, amount);

    //     uint256 grossShares = amount;
    //     uint256 expectedFeeShares = (grossShares * mgmtBPS) / MAX_BPS;
    //     uint256 expectedUserShares = grossShares - expectedFeeShares;

    //     uint256 userBalBefore = vault.balanceOf(user);
    //     uint256 feeBalBefore = vault.balanceOf(feeRecipient);

    //     vault.deposit(amount, user);

    //     // asset accounting
    //     assertEq(asset.balanceOf(address(vault)), amount);
    //     assertEq(vault.totalAssets(), amount);
    //     assertEq(vault.idleAssets(), amount);
    //     assertEq(vault.strategyAssets(), 0);

    //     // share accounting
    //     assertEq(vault.totalSupply(), grossShares);
    //     assertEq(vault.balanceOf(user) - userBalBefore, expectedUserShares);
    //     assertEq(vault.balanceOf(feeRecipient) - feeBalBefore, expectedFeeShares);
    // }

    function testSFVault_SetFeeConfig_RevertsOnInvalidBPS() public {
        uint16 tooHigh = uint16(MAX_BPS + 1);

        vm.prank(takadao);
        vm.expectRevert();
        vault.setFeeConfig(tooHigh, 0, 0);

        vm.prank(takadao);
        vm.expectRevert();
        vault.setFeeConfig(0, tooHigh, 0);
    }

    function testSFVault_SetFeeConfig_UpdatesState() public {
        uint16 mgmtBPS = 300; // 3%
        uint16 perfBPS = 1000; // 10%
        uint16 hurdleBPS = 500; // 5%

        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, perfBPS, hurdleBPS);

        assertEq(vault.managementFeeBPS(), mgmtBPS);
        assertEq(vault.performanceFeeBPS(), perfBPS);
        assertEq(vault.performanceFeeHurdleBPS(), hurdleBPS);
    }

    /*//////////////////////////////////////////////////////////////
                     STRATEGY / TOTAL ASSETS ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function testSFVault_IdleAssets_EqualsVaultBalanceWhenNoStrategy() public {
        uint256 amount = 1_000_000;
        _prepareUser(address(this), amount);

        vault.deposit(amount, address(this));

        assertEq(vault.strategyAssets(), 0);
        assertEq(vault.idleAssets(), asset.balanceOf(address(vault)));
        assertEq(vault.totalAssets(), vault.idleAssets());
    }

    function testSFVault_StrategyAssets_UsesStrategyTotalAssets() public {
        // attach mock strategy
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(takadao);
        vault.setStrategy(ISFStrategy(address(mock)));

        // simulate some assets in strategy
        mock.setMaxTVL(type(uint256).max);
        mock.deposit(500_000, "");

        assertEq(vault.strategyAssets(), 500_000);
    }

    function testSFVault_TotalAssets_SumsIdleAndStrategy() public {
        // 1) deposit into vault -> idle
        uint256 idle = 1_000_000;
        _prepareUser(address(this), idle);
        vault.deposit(idle, address(this));

        // 2) attach mock strategy with some assets
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());
        vm.prank(takadao);
        vault.setStrategy(ISFStrategy(address(mock)));
        mock.deposit(500_000, "");

        assertEq(vault.idleAssets(), idle);
        assertEq(vault.strategyAssets(), 500_000);
        assertEq(vault.totalAssets(), idle + 500_000);
    }

    /*//////////////////////////////////////////////////////////////
                          PERFORMANCE FEES (takeFees)
    //////////////////////////////////////////////////////////////*/

    // function testSFVault_TakeFees_NoAssetsNoShares_NoFeesCharged() public {
    //     // no deposits, no strategy -> totalAssets & totalSupply are zero
    //     (uint256 mgmtShares, uint256 perfShares) = vault.takeFees();

    //     assertEq(mgmtShares, 0);
    //     assertEq(perfShares, 0);
    //     assertEq(vault.balanceOf(feeRecipient), 0);
    //     // highWaterMark should remain 0
    //     assertEq(vault.highWaterMark(), 0);
    // }

    // function testSFVault_TakeFees_WithGain_MintsPerformanceFeeShares() public {
    //     address user = address(this);
    //     uint256 amount = 1_000_000;
    //     uint16 perfBPS = 1000; // 10%

    //     // Only performance fee for this test
    //     vm.prank(takadao);
    //     vault.setFeeConfig(0, perfBPS, 0);

    //     _prepareUser(user, amount);
    //     vault.deposit(amount, user);

    //     // First call establishes high-water-mark, should charge no fees
    //     vm.warp(block.timestamp + 1 days);
    //     (, uint256 perf0) = vault.takeFees();
    //     assertEq(perf0, 0);
    //     uint256 feeBalBefore = vault.balanceOf(feeRecipient);

    //     // Simulate profit: increase vault's asset balance directly
    //     uint256 currentVaultBal = asset.balanceOf(address(vault));
    //     uint256 extra = 200_000;
    //     deal(address(asset), address(vault), currentVaultBal + extra);

    //     // Second call should see gain and mint performance fee shares
    //     vm.warp(block.timestamp + 1 days);
    //     (, uint256 perf1) = vault.takeFees();

    //     assertGt(perf1, 0);
    //     assertGt(vault.balanceOf(feeRecipient), feeBalBefore);
    // }

    /*//////////////////////////////////////////////////////////////
                       NON-TRANSFERABLE SHARES BEHAVIOR
    //////////////////////////////////////////////////////////////*/

    function testSFVault_SharesAreNonTransferable() public {
        // deposit some shares
        uint256 amount = 1_000_000;
        _prepareUser(address(this), amount);
        vault.deposit(amount, address(this));

        uint256 bal = vault.balanceOf(address(this));
        assertGt(bal, 0);

        vm.expectRevert();
        vault.transfer(address(0xBEEF), bal);
    }
}
