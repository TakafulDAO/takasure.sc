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
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract SFVaultTest is Test {
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

    uint256 internal constant MAX_BPS = 10_000;

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
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _prepareUser(address user, uint256 amount) internal {
        deal(address(asset), user, amount);
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
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

    /*//////////////////////////////////////////////////////////////
                                ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function testSFVault_SetTVLCap_RevertsIfNotOperator() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.setTVLCap(123);
    }

    function testSFVault_TakeFees_RevertsIfNotOperator() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.takeFees();
    }

    /*//////////////////////////////////////////////////////////////
                                   SETTERS
    //////////////////////////////////////////////////////////////*/

    function testSFVault_SetTVLCap_UpdatesValue() public {
        uint256 newCap = 1_000_000;

        vm.prank(takadao);
        vault.setTVLCap(newCap);

        assertEq(vault.TVLCap(), newCap);
    }

    function testSFVault_SetStrategy_UpdatesValue() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(takadao);
        vault.setStrategy(ISFStrategy(address(mock)));

        assertEq(address(vault.strategy()), address(mock));
    }

    function testSFVault_SetFeeConfig_UpdatesValues() public {
        uint16 mgmtBPS = 200; // 2%
        uint16 perfBPS = 2000; // 20%
        uint16 hurdleBPS = 1000; // 10%

        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, perfBPS, hurdleBPS);

        assertEq(vault.managementFeeBPS(), mgmtBPS);
        assertEq(vault.performanceFeeBPS(), perfBPS);
        assertEq(vault.performanceFeeHurdleBPS(), hurdleBPS);
    }

    function testSFVault_SetFeeConfig_RevertsOnInvalidFeeBPS() public {
        // managementFeeBPS must be < MAX_BPS
        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__InvalidFeeBPS.selector);
        vault.setFeeConfig(uint16(MAX_BPS), 0, 0);

        // performanceFeeBPS must be <= MAX_BPS
        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__InvalidFeeBPS.selector);
        vault.setFeeConfig(0, uint16(MAX_BPS + 1), 0);

        // hurdle must be <= MAX_BPS
        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__InvalidFeeBPS.selector);
        vault.setFeeConfig(0, 0, uint16(MAX_BPS + 1));
    }

    function testSFVault_PauseAndUnpause_TogglesState() public {
        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(pauser);
        vault.unpause();
        assertTrue(!vault.paused());

        // Unauthorized caller should revert
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.pause();
    }

    /*//////////////////////////////////////////////////////////////
                         TOKEN WHITELIST + CAPS
    //////////////////////////////////////////////////////////////*/

    function testSFVault_WhitelistToken_BasicFlow() public {
        address token = makeAddr("tokenA");

        uint256 lenBefore = vault.whitelistedTokensLength();

        vm.prank(takadao);
        vault.whitelistToken(token);

        assertTrue(vault.isTokenWhitelisted(token));
        assertEq(vault.whitelistedTokensLength(), lenBefore + 1);

        address[] memory tokens = vault.getWhitelistedTokens();

        bool found;
        for (uint256 i; i < tokens.length; i++) {
            if (tokens[i] == token) {
                found = true;
                break;
            }
        }
        assertTrue(found);

        assertEq(vault.tokenHardCapBPS(token), uint16(MAX_BPS));
    }

    function testSFVault_WhitelistToken_RevertsIfZeroToken() public {
        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__InvalidToken.selector);
        vault.whitelistToken(address(0));
    }

    function testSFVault_WhitelistToken_RevertsIfAlreadyWhitelisted() public {
        address token = makeAddr("tokenA");

        vm.prank(takadao);
        vault.whitelistToken(token);

        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__TokenAlreadyWhitelisted.selector);
        vault.whitelistToken(token);
    }

    function testSFVault_WhitelistTokenWithCap_SetsCap() public {
        address token = makeAddr("tokenB");
        uint16 capBPS = 2500;

        vm.prank(takadao);
        vault.whitelistTokenWithCap(token, capBPS);

        assertTrue(vault.isTokenWhitelisted(token));
        assertEq(vault.tokenHardCapBPS(token), capBPS);
    }

    function testSFVault_WhitelistTokenWithCap_RevertsIfInvalidCap() public {
        address token = makeAddr("tokenB");

        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__InvalidCapBPS.selector);
        vault.whitelistTokenWithCap(token, uint16(MAX_BPS + 1));
    }

    function testSFVault_SetTokenHardCap_UpdatesCap() public {
        address token = makeAddr("tokenC");

        vm.prank(takadao);
        vault.whitelistToken(token);

        vm.prank(takadao);
        vault.setTokenHardCap(token, 1234);

        assertEq(vault.tokenHardCapBPS(token), 1234);
    }

    function testSFVault_SetTokenHardCap_RevertsIfNotWhitelisted() public {
        address token = makeAddr("tokenX");
        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__TokenNotWhitelisted.selector);
        vault.setTokenHardCap(token, 1);
    }

    function testSFVault_SetTokenHardCap_RevertsIfInvalidCap() public {
        address token = makeAddr("tokenY");

        vm.prank(takadao);
        vault.whitelistToken(token);

        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__InvalidCapBPS.selector);
        vault.setTokenHardCap(token, uint16(MAX_BPS + 1));
    }

    function testSFVault_RemoveTokenFromWhitelist_Removes() public {
        address token = makeAddr("tokenD");

        vm.prank(takadao);
        vault.whitelistToken(token);
        assertTrue(vault.isTokenWhitelisted(token));

        vm.prank(takadao);
        vault.removeTokenFromWhitelist(token);

        assertTrue(!vault.isTokenWhitelisted(token));
        assertEq(vault.whitelistedTokensLength(), 1);
    }

    function testSFVault_RemoveTokenFromWhitelist_RevertsIfNotWhitelisted() public {
        address token = makeAddr("tokenZ");

        vm.prank(takadao);
        vm.expectRevert(SFVault.SFVault__TokenNotWhitelisted.selector);
        vault.removeTokenFromWhitelist(token);
    }

    /*//////////////////////////////////////////////////////////////
                            MAX DEPOSIT / MAX MINT
    //////////////////////////////////////////////////////////////*/

    function testSFVault_MaxDeposit_UncappedWhenTVLCapZero() public {
        vm.prank(takadao);
        vault.setTVLCap(0);

        uint256 max0 = vault.maxDeposit(address(this));
        assertGt(max0, 1e30); // should be effectively uncapped
    }

    function testSFVault_MaxDeposit_ZeroWhenCapReached() public {
        uint256 cap = 500_000;

        vm.prank(takadao);
        vault.setTVLCap(cap);

        _prepareUser(address(this), cap);
        vault.deposit(cap, address(this));

        assertEq(vault.maxDeposit(address(this)), 0);
    }

    function testSFVault_MaxDeposit_RespectsTVLCap_NoFee() public {
        uint256 cap = 1_000_000;

        vm.prank(takadao);
        vault.setTVLCap(cap);

        assertEq(vault.maxDeposit(address(this)), cap);

        uint256 depositAmount = cap / 2;
        _prepareUser(address(this), depositAmount);
        vault.deposit(depositAmount, address(this));

        assertEq(vault.maxDeposit(address(this)), cap - depositAmount);
    }

    function testSFVault_MaxDeposit_AdjustsForManagementFee_WhenCapped() public {
        uint256 cap = 1_000_000;
        uint16 mgmtBPS = 1000; // 10%

        vm.prank(takadao);
        vault.setTVLCap(cap);

        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        // With fee, maxDeposit should return the gross amount user can send s.t. net fits in cap
        uint256 expectedGross = Math.mulDiv(cap, MAX_BPS, (MAX_BPS - mgmtBPS));
        assertEq(vault.maxDeposit(address(this)), expectedGross);

        // deposit at maxDeposit should pass
        _prepareUser(address(this), expectedGross);
        vault.deposit(expectedGross, address(this));

        assertEq(vault.totalAssets(), cap); // net in vault should hit cap
        assertEq(vault.maxDeposit(address(this)), 0);
    }

    function testSFVault_MaxMint_UsesMaxDepositAndPreviewDeposit() public {
        uint256 cap = 1_000_000;
        uint16 mgmtBPS = 500; // 5%

        vm.prank(takadao);
        vault.setTVLCap(cap);

        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        uint256 maxAssets = vault.maxDeposit(address(this));
        uint256 expectedMaxMint = vault.previewDeposit(maxAssets);

        assertEq(vault.maxMint(address(this)), expectedMaxMint);
    }

    /*//////////////////////////////////////////////////////////////
                           PREVIEW DEPOSIT / MINT
    //////////////////////////////////////////////////////////////*/

    function testSFVault_PreviewDeposit_ZeroAssets_ReturnsZero() public view {
        assertEq(vault.previewDeposit(0), 0);
    }

    function testSFVault_PreviewDeposit_WithFee_UsesNetAssets() public {
        uint16 mgmtBPS = 500; // 5%
        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        uint256 amount = 1_000_000;
        uint256 feeAssets = (amount * mgmtBPS) / MAX_BPS;
        uint256 netAssets = amount - feeAssets;

        uint256 preview = vault.previewDeposit(amount);
        uint256 expectedShares = vault.convertToShares(netAssets);

        assertEq(preview, expectedShares);
    }

    function testSFVault_PreviewDeposit_SkipsFeeIfRecipientZero() public {
        uint16 mgmtBPS = 500; // 5%
        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        _mockFeeRecipient(address(0));

        uint256 amount = 1_000_000;
        assertEq(vault.previewDeposit(amount), vault.convertToShares(amount));
    }

    function testSFVault_PreviewMint_ZeroShares_ReturnsZero() public view {
        assertEq(vault.previewMint(0), 0);
    }

    function testSFVault_PreviewMint_NoFeeWhenMgmtBPSZero() public {
        vm.prank(takadao);
        vault.setFeeConfig(0, 0, 0);

        uint256 shares = 123_456;
        assertEq(vault.previewMint(shares), vault.convertToAssets(shares));
    }

    function testSFVault_PreviewMint_WithFee_AddsCeilFee() public {
        uint16 mgmtBPS = 500; // 5%
        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        uint256 shares = 100_000;
        uint256 netAssets = vault.convertToAssets(shares);

        uint256 feeAssets = Math.mulDiv(netAssets, mgmtBPS, (MAX_BPS - mgmtBPS), Math.Rounding.Ceil);

        assertEq(vault.previewMint(shares), netAssets + feeAssets);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function testSFVault_Deposit_RevertsOnZeroAssets() public {
        vm.expectRevert(SFVault.SFVault__ZeroAssets.selector);
        vault.deposit(0, address(this));
    }

    function testSFVault_Deposit_RevertsWhenExceedsCap() public {
        uint256 cap = 100_000;

        vm.prank(takadao);
        vault.setTVLCap(cap);

        _prepareUser(address(this), cap + 1);

        vm.expectRevert(SFVault.SFVault__ExceedsMaxDeposit.selector);
        vault.deposit(cap + 1, address(this));
    }

    function testSFVault_Deposit_TakesManagementFeeAndMintsNetShares() public {
        uint16 mgmtBPS = 500; // 5%
        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        uint256 amount = 1_000_000;
        _prepareUser(address(this), amount);

        uint256 feeAssets = (amount * mgmtBPS) / MAX_BPS;
        uint256 netAssets = amount - feeAssets;

        uint256 sharesOut = vault.deposit(amount, address(this));

        assertEq(sharesOut, vault.convertToShares(netAssets));
        assertEq(asset.balanceOf(address(vault)), netAssets);
        assertEq(asset.balanceOf(feeRecipient), feeAssets);
        assertEq(vault.totalAssets(), netAssets);
        assertEq(vault.balanceOf(address(this)), sharesOut);
    }

    function testSFVault_Deposit_SkipsFeeIfRecipientZero() public {
        uint16 mgmtBPS = 500; // 5%
        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        _mockFeeRecipient(address(0));

        uint256 amount = 1_000_000;
        _prepareUser(address(this), amount);

        uint256 sharesOut = vault.deposit(amount, address(this));

        assertEq(asset.balanceOf(address(vault)), amount);
        assertEq(vault.totalAssets(), amount);
        assertEq(sharesOut, vault.convertToShares(amount));
    }

    function testSFVault_Deposit_RevertsWhenNetSharesZero() public {
        vm.prank(takadao);
        vault.setFeeConfig(0, 0, 0);

        uint256 seed = 1_000_000;
        _prepareUser(address(this), seed);
        vault.deposit(seed, address(this));

        // Ensure cap won't block the deposit.
        // We want: totalAssets after donation == seed + 1, and still allow depositing 1.
        vm.prank(takadao);
        vault.setTVLCap(seed + 2);

        // Small donation is enough to make convertToShares(1) round down to 0
        _donateToVault(1);

        _prepareUser(address(this), 1);
        vm.expectRevert(SFVault.SFVault__ZeroShares.selector);
        vault.deposit(1, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                                  MINT
    //////////////////////////////////////////////////////////////*/

    function testSFVault_Mint_RevertsOnZeroShares() public {
        vm.expectRevert(SFVault.SFVault__ZeroShares.selector);
        vault.mint(0, address(this));
    }

    function testSFVault_Mint_TakesManagementFeeAndReturnsGrossAssets() public {
        uint16 mgmtBPS = 500; // 5%
        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        uint256 shares = 1_000_000;

        uint256 grossAssets = vault.previewMint(shares);
        _prepareUser(address(this), grossAssets);

        uint256 spent = vault.mint(shares, address(this));
        assertEq(spent, grossAssets);

        // vault keeps netAssets == convertToAssets(shares) when supply was 0 (1:1)
        uint256 netAssets = vault.convertToAssets(shares);

        assertEq(asset.balanceOf(address(vault)), netAssets);
        assertEq(vault.balanceOf(address(this)), shares);
        assertEq(vault.totalAssets(), netAssets);
        assertEq(asset.balanceOf(feeRecipient), grossAssets - netAssets);
    }

    function testSFVault_Mint_RevertsWhenExceedsCap() public {
        uint16 mgmtBPS = 500; // 5%
        uint256 cap = 100_000;

        vm.prank(takadao);
        vault.setTVLCap(cap);

        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        // Mint shares requiring > cap net will revert due to grossAssets > maxDeposit
        uint256 shares = cap + 1;
        uint256 grossAssets = vault.previewMint(shares);
        _prepareUser(address(this), grossAssets);

        vm.expectRevert(SFVault.SFVault__ExceedsMaxDeposit.selector);
        vault.mint(shares, address(this));
    }

    /*//////////////////////////////////////////////////////////////
                       STRATEGY / TOTAL ASSETS ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function testSFVault_IdleAssets_StrategyAssets_TotalAssets_Accounting() public {
        uint256 amount = 1_000_000;
        _prepareUser(address(this), amount);
        vault.deposit(amount, address(this));

        assertEq(vault.strategyAssets(), 0);
        assertEq(vault.idleAssets(), asset.balanceOf(address(vault)));
        assertEq(vault.totalAssets(), vault.idleAssets());

        // attach mock strategy
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());
        vm.prank(takadao);
        vault.setStrategy(ISFStrategy(address(mock)));

        // put assets into strategy (independent of vault; totalAssets() sums both)
        uint256 stratAssets = 500_000;
        deal(address(asset), address(this), stratAssets);
        asset.approve(address(mock), stratAssets);
        mock.setMaxTVL(type(uint256).max);
        mock.deposit(stratAssets, "");

        assertEq(vault.strategyAssets(), mock.totalAssets());
        assertEq(vault.totalAssets(), vault.idleAssets() + vault.strategyAssets());
    }

    /*//////////////////////////////////////////////////////////////
                         NON-TRANSFERABLE SHARES
    //////////////////////////////////////////////////////////////*/

    function testSFVault_SharesAreNonTransferable_TransferReverts() public {
        uint256 amount = 1_000_000;
        _prepareUser(address(this), amount);
        vault.deposit(amount, address(this));

        uint256 bal = vault.balanceOf(address(this));
        assertGt(bal, 0);

        vm.expectRevert(SFVault.SFVault__NonTransferableShares.selector);
        vault.transfer(makeAddr("bob"), bal);
    }

    function testSFVault_SharesAreNonTransferable_RedeemBurnAllowed() public {
        uint256 amount = 1_000_000;
        _prepareUser(address(this), amount);
        vault.deposit(amount, address(this));

        uint256 shares = vault.balanceOf(address(this));
        assertGt(shares, 0);

        uint256 assetsOut = vault.redeem(shares, address(this), address(this));
        assertEq(assetsOut, amount); // mgmt fee default 0 in this test
        assertEq(vault.balanceOf(address(this)), 0);
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
        _prepareUser(address(this), amount);
        vault.deposit(amount, address(this));

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
        _prepareUser(address(this), amount);
        vault.deposit(amount, address(this));

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
        _prepareUser(address(this), amount);
        vault.deposit(amount, address(this));

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
        _prepareUser(address(this), amount);
        vault.deposit(amount, address(this));

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
        _prepareUser(address(this), amount);
        vault.deposit(amount, address(this));

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
        _prepareUser(address(this), amount);
        vault.deposit(amount, address(this));

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
                               UUPS (COVERAGE)
    //////////////////////////////////////////////////////////////*/

    // todo: check
    function testSFVault_UpgradeTo_Works() public {
        SFVault newImpl = new SFVault();

        vm.prank(takadao);
        vault.upgradeToAndCall(address(newImpl), "");

        // sanity: state should remain accessible
        vault.totalAssets();
    }
}
