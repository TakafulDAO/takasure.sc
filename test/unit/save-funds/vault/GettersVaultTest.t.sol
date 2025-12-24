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

contract GettersVaultTest is Test {
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
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);

        vm.prank(backend);
        vault.registerMember(user);
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
        vault.setAggregator(ISFStrategy(address(mock)));

        uint256 amt = 777 * ONE_USDC;

        // IMPORTANT: MockSFStrategy.totalAssets() is not tied to raw token balance.
        // Use its deposit path to update internal accounting.
        deal(address(asset), address(this), amt);
        asset.approve(address(mock), amt);
        mock.deposit(amt, "");

        assertEq(vault.getAggregatorAssets(), vault.aggregatorAssets());
        assertEq(vault.getAggregatorAssets(), mock.totalAssets());
        assertEq(vault.getAggregatorAssets(), amt);
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
        address _user = makeAddr("_user");
        assertEq(vault.getUserShares(_user), 0);
        assertEq(vault.getUserAssets(_user), 0);
    }

    function testSFVault_GetUserTotalDeposited_TracksDepositAndMint() public {
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

    function testSFVault_GetAggregatorAllocation_ZeroWhenNoTVL() public view {
        assertEq(vault.getAggregatorAllocation(), 0);
    }

    function testSFVault_GetAggregatorAllocation_ComputesBps() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());
        vm.prank(takadao);
        vault.setAggregator(ISFStrategy(address(mock)));

        // tvl = 1_000, strategy = 800, idle = 200 => 8000 bps
        deal(address(asset), address(vault), 200 * ONE_USDC);

        uint256 stratAssets = 800 * ONE_USDC;
        deal(address(asset), address(this), stratAssets);
        asset.approve(address(mock), stratAssets);
        mock.deposit(stratAssets, "");

        assertEq(mock.totalAssets(), stratAssets);
        assertEq(vault.getAggregatorAllocation(), 8_000);
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

    function testSFVault_GetVaultPerformanceSince_ReturnsZeroWhenNoShares() public view {
        assertEq(vault.getVaultPerformanceSince(0), 0);
        assertEq(vault.getVaultPerformanceSince(1), 0);
    }

    function testSFVault_GetVaultPerformanceSince_TimestampGreaterThanLastReportReturnsZero() public {
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
                            ERC721
    //////////////////////////////////////////////////////////////*/

    function testSFVault_onERC721Received_ReturnsSelector() public view {
        bytes4 sel = vault.onERC721Received(address(1), address(2), 123, "0x");
        assertEq(sel, IERC721Receiver.onERC721Received.selector);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _prepareUser(address _user, uint256 amount) internal {
        deal(address(asset), _user, amount);
        vm.prank(_user);
        asset.approve(address(vault), type(uint256).max);
    }

    function _mockFeeRecipient(address recipient) internal {
        // Return extra static fields to be compatible if ProtocolAddress has >2 fields
        vm.mockCall(
            address(addrMgr),
            abi.encodeWithSignature("getProtocolAddressByName(string)", "ADMIN__SF_FEE_RECEIVER"),
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
