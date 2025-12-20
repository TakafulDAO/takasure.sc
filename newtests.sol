// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

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
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract SFVaultGettersAndAccountingTest is Test {
    DeployManagers internal managersDeployer;
    DeploySFVault internal vaultDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault internal vault;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;

    IERC20 internal asset;
    address internal takadao; // operator
    address internal feeRecipient;
    address internal pauser = makeAddr("pauser");

    uint256 internal constant ONE_USDC = 1e6;

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

        vault = vaultDeployer.run(_addrMgr, config, address(_modMgr));
        asset = IERC20(vault.asset());

        feeRecipient = makeAddr("feeRecipient");

        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("SF_VAULT_FEE_RECIPIENT", feeRecipient, ProtocolAddressType.Admin);
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);
    }

    function _prepareUser(address user, uint256 amount) internal {
        deal(address(asset), user, amount);
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            GETTERS: WRAPPERS
    //////////////////////////////////////////////////////////////*/

    function testSFVault_GetIdleAssets_WrapperMatchesIdleAssets() public {
        uint256 amt = 1234 * ONE_USDC;
        deal(address(asset), address(vault), amt);

        assertEq(vault.getIdleAssets(), vault.idleAssets());
        assertEq(vault.getIdleAssets(), amt);
    }

    function testSFVault_GetStrategyAssets_WrapperMatchesStrategyAssets() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(takadao);
        vault.setStrategy(ISFStrategy(address(mock)));

        uint256 amt = 777 * ONE_USDC;
        deal(address(asset), address(mock), amt);

        assertEq(vault.getStrategyAssets(), vault.strategyAssets());
        assertEq(vault.getStrategyAssets(), amt);
    }

    function testSFVault_GetVaultTVL_WrapperMatchesTotalAssets() public {
        uint256 amt = 555 * ONE_USDC;
        deal(address(asset), address(vault), amt);

        assertEq(vault.getVaultTVL(), vault.totalAssets());
        assertEq(vault.getVaultTVL(), amt);
    }

    /*//////////////////////////////////////////////////////////////
                        USER ACCOUNTING GETTERS
    //////////////////////////////////////////////////////////////*/

    function testSFVault_GetUserAssets_ZeroSharesReturnsZero() public {
        address user = makeAddr("user");
        assertEq(vault.getUserShares(user), 0);
        assertEq(vault.getUserAssets(user), 0);
    }

    function testSFVault_GetUserTotalDeposited_TracksDepositAndMint() public {
        address user = makeAddr("user");
        _prepareUser(user, 10_000 * ONE_USDC);

        uint256 a1 = 1_000 * ONE_USDC;

        vm.prank(user);
        vault.deposit(a1, user);

        assertEq(vault.getUserTotalDeposited(user), a1);

        // mint exact shares
        uint256 sharesToMint = 100 * ONE_USDC;
        vm.prank(user);
        uint256 grossPaid = vault.mint(sharesToMint, user);

        assertEq(vault.getUserTotalDeposited(user), a1 + grossPaid);
        assertEq(vault.getUserShares(user), vault.balanceOf(user));
    }

    function testSFVault_GetUserTotalWithdrawn_TracksWithdrawAndRedeem() public {
        address user = makeAddr("user");
        _prepareUser(user, 10_000 * ONE_USDC);

        uint256 depositAmt = 1_000 * ONE_USDC;
        vm.prank(user);
        vault.deposit(depositAmt, user);

        // Withdraw a portion
        uint256 withdrawAmt = 200 * ONE_USDC;
        vm.prank(user);
        vault.withdraw(withdrawAmt, user, user);

        assertEq(vault.getUserTotalWithdrawn(user), withdrawAmt);

        // Redeem remaining shares
        uint256 remainingShares = vault.balanceOf(user);
        vm.prank(user);
        uint256 redeemedAssets = vault.redeem(remainingShares, user, user);

        assertEq(vault.getUserTotalWithdrawn(user), withdrawAmt + redeemedAssets);
        assertEq(vault.balanceOf(user), 0);
    }

    function testSFVault_GetUserNetDeposited_ReturnsDepositedMinusWithdrawn_WhenLossOrNoProfit() public {
        address user = makeAddr("user");
        _prepareUser(user, 10_000 * ONE_USDC);

        uint256 depositAmt = 1_000 * ONE_USDC;
        vm.prank(user);
        vault.deposit(depositAmt, user);

        uint256 withdrawAmt = 400 * ONE_USDC;
        vm.prank(user);
        vault.withdraw(withdrawAmt, user, user);

        assertEq(vault.getUserNetDeposited(user), depositAmt - withdrawAmt);
    }

    function testSFVault_GetUserNetDeposited_ClampsToZero_WhenWithdrawnExceedsDepositedOnProfit() public {
        address user = makeAddr("user");
        _prepareUser(user, 10_000 * ONE_USDC);

        uint256 depositAmt = 1_000 * ONE_USDC;
        vm.prank(user);
        vault.deposit(depositAmt, user);

        // Simulate profit: increase idle assets without minting shares.
        deal(address(asset), address(vault), depositAmt + 500 * ONE_USDC);

        uint256 userAssets = vault.convertToAssets(vault.balanceOf(user));
        vm.prank(user);
        vault.withdraw(userAssets, user, user);

        assertEq(vault.getUserTotalDeposited(user), depositAmt);
        assertGt(vault.getUserTotalWithdrawn(user), depositAmt);
        assertEq(vault.getUserNetDeposited(user), 0);
    }

    function testSFVault_GetUserPnL_PositiveAfterProfit() public {
        address user = makeAddr("user");
        _prepareUser(user, 10_000 * ONE_USDC);

        uint256 depositAmt = 1_000 * ONE_USDC;
        vm.prank(user);
        vault.deposit(depositAmt, user);

        // Profit: add +250 USDC to vault
        deal(address(asset), address(vault), depositAmt + 250 * ONE_USDC);

        int256 pnl = vault.getUserPnL(user);
        assertGt(pnl, 0);

        uint256 currentAssets = vault.getUserAssets(user);
        assertEq(pnl, int256(currentAssets) - int256(depositAmt));
    }

    function testSFVault_GetUserPnL_NegativeAfterLoss() public {
        address user = makeAddr("user");
        _prepareUser(user, 10_000 * ONE_USDC);

        uint256 depositAmt = 1_000 * ONE_USDC;
        vm.prank(user);
        vault.deposit(depositAmt, user);

        // Loss: slash vault balance to 600
        deal(address(asset), address(vault), 600 * ONE_USDC);

        int256 pnl = vault.getUserPnL(user);
        assertLt(pnl, 0);

        uint256 currentAssets = vault.getUserAssets(user);
        assertEq(pnl, int256(currentAssets) - int256(depositAmt));
    }

    /*//////////////////////////////////////////////////////////////
                        STRATEGY ALLOCATION GETTER
    //////////////////////////////////////////////////////////////*/

    function testSFVault_GetStrategyAllocation_ZeroWhenNoTVL() public {
        assertEq(vault.getStrategyAllocation(), 0);
    }

    function testSFVault_GetStrategyAllocation_ComputesBps() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());
        vm.prank(takadao);
        vault.setStrategy(ISFStrategy(address(mock)));

        // tvl = 1_000, strategy = 800, idle = 200 => 8000 bps
        deal(address(asset), address(vault), 200 * ONE_USDC);
        deal(address(asset), address(mock), 800 * ONE_USDC);

        assertEq(vault.getStrategyAllocation(), 8_000);
    }

    /*//////////////////////////////////////////////////////////////
                            LAST REPORT GETTER
    //////////////////////////////////////////////////////////////*/

    function testSFVault_GetLastReport_InitialThenUpdatedByTakeFees() public {
        (uint256 ts0, uint256 assets0) = vault.getLastReport();
        assertEq(ts0, 0);
        assertEq(assets0, vault.totalAssets());

        vm.warp(12345);
        vm.prank(takadao);
        vault.takeFees();

        (uint256 ts1, uint256 assets1) = vault.getLastReport();
        assertEq(ts1, 12345);
        assertEq(assets1, vault.totalAssets());
    }

    /*//////////////////////////////////////////////////////////////
                        VAULT PERFORMANCE GETTER
    //////////////////////////////////////////////////////////////*/

    function testSFVault_GetVaultPerformanceSince_ReturnsZeroWhenNoShares() public {
        assertEq(vault.getVaultPerformanceSince(0), 0);
        assertEq(vault.getVaultPerformanceSince(1), 0);
    }

    function testSFVault_GetVaultPerformanceSince_TimestampGreaterThanLastReportReturnsZero() public {
        address user = makeAddr("user");
        _prepareUser(user, 10_000 * ONE_USDC);
        vm.prank(user);
        vault.deposit(1_000 * ONE_USDC, user);

        // lastReport still 0 until takeFees
        assertEq(vault.getVaultPerformanceSince(1), 0);
    }

    function testSFVault_GetVaultPerformanceSince_BaseHighWaterMarkZeroReturnsZero() public {
        vm.warp(777);
        vm.prank(takadao);
        vault.takeFees();

        assertEq(vault.getVaultPerformanceSince(777), 0);
    }

    function testSFVault_GetVaultPerformanceSince_PositiveAndNegativeRelativeToBaseline() public {
        address user = makeAddr("user");
        _prepareUser(user, 10_000 * ONE_USDC);

        vm.prank(user);
        vault.deposit(1_000 * ONE_USDC, user);

        // Establish baseline (sets highWaterMark and lastReport)
        vm.warp(1000);
        vm.prank(takadao);
        vault.takeFees();

        (uint256 lastReportTs,) = vault.getLastReport();

        // +10%
        deal(address(asset), address(vault), 1_100 * ONE_USDC);
        assertGt(vault.getVaultPerformanceSince(lastReportTs), 0);

        // -10%
        deal(address(asset), address(vault), 900 * ONE_USDC);
        assertLt(vault.getVaultPerformanceSince(lastReportTs), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            ERC721 HELPERS
    //////////////////////////////////////////////////////////////*/

    function testSFVault_onERC721Received_ReturnsSelector() public {
        bytes4 sel = vault.onERC721Received(address(1), address(2), 123, "0x");
        assertEq(sel, IERC721Receiver.onERC721Received.selector);
    }

    function testSFVault_setERC721ApprovalForAll_OnlyOperator_AndMakesCall() public {
        address attacker = makeAddr("attacker");
        address nft = makeAddr("nft");
        address op = makeAddr("op");

        vm.prank(attacker);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.setERC721ApprovalForAll(nft, op, true);

        vm.expectCall(nft, abi.encodeWithSelector(IERC721.setApprovalForAll.selector, op, true));
        vm.prank(takadao);
        vault.setERC721ApprovalForAll(nft, op, true);
    }

    /*//////////////////////////////////////////////////////////////
                    (OPTIONAL) COVER INTERFACE STUBS
    //////////////////////////////////////////////////////////////*/

    function testSFVault_InterfaceStubs_AreCallable() public {
        // If these functions still exist as no-ops to satisfy ISFVault, call them once for coverage.
        // If you removed them from the interface/contract, delete this test.
        vault.harvest(address(0));
        vault.rebalance(address(0), address(0), 0);
        vault.investIntoStrategy(address(0), 0);
        vault.withdrawFromStrategy(address(0), 0);
    }
}
