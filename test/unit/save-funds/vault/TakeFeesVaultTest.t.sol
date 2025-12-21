// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFVault} from "test/utils/05-DeploySFVault.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {MockSFStrategy} from "test/mocks/MockSFStrategy.sol";
import {MockERC721ApprovalForAll} from "test/mocks/MockERC721ApprovalForAll.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract TakeFeesVaultTest is Test {
    DeployManagers internal managersDeployer;
    DeploySFVault internal vaultDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault internal vault;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;

    IERC20 internal asset;
    address internal takadao; // operator
    address internal feeRecipient;
    address internal backend;
    address internal pauser = makeAddr("pauser");
    address internal user = makeAddr("user");

    uint256 internal constant MAX_BPS = 10_000;
    uint256 internal constant ONE_USDC = 1e6;

    function setUp() public {
        managersDeployer = new DeployManagers();
        vaultDeployer = new DeploySFVault();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();
        (address operatorAddr,,, address backendAddr,,,) = addressesAndRoles.run(_addrMgr, config, address(_modMgr));

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        takadao = operatorAddr;
        backend = backendAddr;
        vault = vaultDeployer.run(addrMgr);
        asset = IERC20(vault.asset());

        feeRecipient = makeAddr("feeRecipient");

        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("SF_VAULT_FEE_RECIPIENT", feeRecipient, ProtocolAddressType.Admin);
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);

        vm.prank(backend);
        vault.registerMember(user);
    }

    /*//////////////////////////////////////////////////////////////
                                TAKE FEES
    //////////////////////////////////////////////////////////////*/

    function testSFVault_TakeFees_ReturnsZeroIfFeeRecipientZero() public {
        _mockFeeRecipient(address(0));

        uint64 beforeReport = vault.lastReport();

        vm.warp(block.timestamp + 1);
        vm.prank(takadao);
        (uint256 mgmtFee, uint256 perfFee) = vault.takeFees();

        assertEq(mgmtFee, 0);
        assertEq(perfFee, 0);
        assertEq(vault.lastReport(), uint64(block.timestamp));
        assertTrue(vault.lastReport() >= beforeReport);
    }

    function testSFVault_TakeFees_ReturnsZeroIfNoSharesOrAssets() public {
        vm.prank(takadao);
        vault.setFeeConfig(0, 2000, 0);

        vm.warp(block.timestamp + 1);
        vm.prank(takadao);
        (uint256 mgmtFee, uint256 perfFee) = vault.takeFees();

        assertEq(mgmtFee, 0);
        assertEq(perfFee, 0);
        assertEq(vault.highWaterMark(), 0);
    }

    function testSFVault_TakeFees_PerformanceFeeBPSZero_UpdatesHWMNoTransfer() public {
        vm.prank(takadao);
        vault.setFeeConfig(0, 0, 0);

        uint256 amount = 1_000_000;
        _prepareUser(user, amount);

        // profit via donation
        _donateToVault(100_000);

        uint256 feeBalBefore = asset.balanceOf(feeRecipient);

        vm.warp(block.timestamp + 1);
        vm.prank(takadao);
        (uint256 mgmtFee, uint256 perfFee) = vault.takeFees();

        assertEq(mgmtFee, 0);
        assertEq(perfFee, 0);
        assertEq(asset.balanceOf(feeRecipient), feeBalBefore);

        // HWM updated to current assets/share
        uint256 aps = _assetsPerShareWad(vault.totalAssets(), vault.totalSupply());
        assertEq(vault.highWaterMark(), aps);
    }

    function testSFVault_TakeFees_NoGain_ReturnsZeroAndUpdatesHWM() public {
        vm.prank(takadao);
        vault.setFeeConfig(0, 2000, 0);

        uint256 amount = 1_000_000;
        _prepareUser(user, amount);

        // First call should establish/update HWM without charging (no gain)
        uint256 feeBalBefore = asset.balanceOf(feeRecipient);

        vm.warp(block.timestamp + 1);
        vm.prank(takadao);
        (, uint256 perfFee1) = vault.takeFees();

        assertEq(perfFee1, 0);
        assertEq(asset.balanceOf(feeRecipient), feeBalBefore);

        // Second call immediately after should also be no gain
        vm.warp(block.timestamp + 2);
        vm.prank(takadao);
        (, uint256 perfFee2) = vault.takeFees();
        assertEq(perfFee2, 0);
    }

    function testSFVault_TakeFees_WithGain_ChargesPerformanceFee() public {
        uint16 perfBPS = 2000; // 20%
        vm.prank(takadao);
        vault.setFeeConfig(0, perfBPS, 0);

        uint256 amount = 1_000_000;
        _prepareUser(user, amount);

        // Establish HWM
        vm.warp(block.timestamp + 1);
        vm.prank(takadao);
        vault.takeFees();

        // Donate profit to vault (idle) => gain
        uint256 profit = 100_000;
        _donateToVault(profit);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalShares = vault.totalSupply();
        uint256 hwmBefore = vault.highWaterMark();
        uint64 lastReportBefore = vault.lastReport();

        uint256 currentAPS = _assetsPerShareWad(totalAssetsBefore, totalShares);
        uint256 gainPerShareWad = currentAPS - hwmBefore;
        uint256 grossProfitAssets = (gainPerShareWad * totalShares) / 1e18;
        uint256 expectedFee = (grossProfitAssets * perfBPS) / MAX_BPS;

        uint256 feeAssetBefore = asset.balanceOf(feeRecipient);
        uint256 vaultBalBefore = asset.balanceOf(address(vault));

        vm.warp(block.timestamp + 2);
        vm.prank(takadao);
        (, uint256 charged) = vault.takeFees();

        assertEq(charged, expectedFee);
        assertEq(asset.balanceOf(feeRecipient), feeAssetBefore + expectedFee);
        assertEq(asset.balanceOf(address(vault)), vaultBalBefore - expectedFee);
        assertEq(vault.lastReport(), uint64(block.timestamp));
        assertTrue(vault.lastReport() > lastReportBefore);

        uint256 newTotalAssets = totalAssetsBefore - expectedFee;
        uint256 expectedNewHWM = _assetsPerShareWad(newTotalAssets, totalShares);
        assertEq(vault.highWaterMark(), expectedNewHWM);
    }

    function testSFVault_TakeFees_WithHurdle_ProfitBelowHurdle_NoFee() public {
        uint16 perfBPS = 2000; // 20%
        uint16 hurdleBPS = 1000; // 10% APY
        vm.prank(takadao);
        vault.setFeeConfig(0, perfBPS, hurdleBPS);

        uint256 amount = 1_000_000;
        _prepareUser(user, amount);

        // Establish HWM
        vm.warp(block.timestamp + 1);
        vm.prank(takadao);
        vault.takeFees();

        // Wait 1 year to maximize hurdle allowance
        uint64 report = vault.lastReport();
        vm.warp(uint256(report) + 365 days);

        // Small profit, likely <= hurdleReturnedAssets
        _donateToVault(50_000);

        uint256 feeBalBefore = asset.balanceOf(feeRecipient);

        vm.prank(takadao);
        (, uint256 perfFee) = vault.takeFees();

        assertEq(perfFee, 0);
        assertEq(asset.balanceOf(feeRecipient), feeBalBefore);
        // HWM should still update to current APS
        uint256 aps = _assetsPerShareWad(vault.totalAssets(), vault.totalSupply());
        assertEq(vault.highWaterMark(), aps);
    }

    function testSFVault_TakeFees_WithHurdle_ProfitAboveHurdle_FeeOnExcess() public {
        uint16 perfBPS = 2000; // 20%
        uint16 hurdleBPS = 1000; // 10% APY
        vm.prank(takadao);
        vault.setFeeConfig(0, perfBPS, hurdleBPS);

        uint256 amount = 1_000_000;
        _prepareUser(user, amount);

        // Establish HWM
        vm.warp(block.timestamp + 1);
        vm.prank(takadao);
        vault.takeFees();

        uint64 report = vault.lastReport();
        vm.warp(uint256(report) + 365 days);

        // Large profit
        _donateToVault(300_000);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalShares = vault.totalSupply();
        uint256 hwmBefore = vault.highWaterMark();

        uint256 currentAPS = _assetsPerShareWad(totalAssetsBefore, totalShares);
        uint256 gainPerShareWad = currentAPS - hwmBefore;
        uint256 grossProfitAssets = (gainPerShareWad * totalShares) / 1e18;

        uint256 elapsed = block.timestamp - report;
        uint256 hurdleReturnedAssets = (totalAssetsBefore * hurdleBPS * elapsed) / (MAX_BPS * 365 days);

        uint256 feeableProfit =
            grossProfitAssets > hurdleReturnedAssets ? (grossProfitAssets - hurdleReturnedAssets) : 0;
        uint256 expectedFee = (feeableProfit * perfBPS) / MAX_BPS;

        uint256 feeBalBefore = asset.balanceOf(feeRecipient);

        vm.prank(takadao);
        (, uint256 perfFee) = vault.takeFees();

        assertEq(perfFee, expectedFee);
        assertEq(asset.balanceOf(feeRecipient), feeBalBefore + expectedFee);
    }

    function testSFVault_TakeFees_RevertsIfInsufficientUSDCForFees() public {
        uint16 perfBPS = 2000; // 20%
        vm.prank(takadao);
        vault.setFeeConfig(0, perfBPS, 0);

        uint256 amount = 1_000_000;
        _prepareUser(user, amount);

        // Establish HWM at current APS
        vm.warp(block.timestamp + 1);
        vm.prank(takadao);
        vault.takeFees();

        // Set strategy and put huge assets into it, so totalAssets spikes but idle remains ~amount
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());
        vm.prank(takadao);
        vault.setStrategy(ISFStrategy(address(mock)));

        uint256 stratProfit = 10_000_000; // makes perf fee > idle
        deal(address(asset), address(this), stratProfit);
        asset.approve(address(mock), stratProfit);
        mock.setMaxTVL(type(uint256).max);
        mock.deposit(stratProfit, "");

        vm.warp(block.timestamp + 2);
        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__InsufficientUSDCForFees.selector);
        vault.takeFees();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _prepareUser(address user, uint256 amount) internal {
        deal(address(asset), user, amount);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _mockFeeRecipient(address recipient) internal {
        // Return extra static fields to be compatible if ProtocolAddress has >2 fields
        vm.mockCall(
            address(addrMgr),
            abi.encodeWithSignature("getProtocolAddressByName(string)", "SF_VAULT_FEE_RECIPIENT"),
            abi.encode(recipient, uint8(0), false)
        );
    }

    function _donateToVault(uint256 amount) internal {
        uint256 cur = asset.balanceOf(address(vault));
        deal(address(asset), address(vault), cur + amount);
    }

    function _assetsPerShareWad(uint256 totalAssets_, uint256 totalShares_) internal pure returns (uint256) {
        return (totalAssets_ * 1e18) / totalShares_;
    }
}
