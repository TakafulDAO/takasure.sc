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

contract DepositAndMintVaultTest is Test {
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
                            MAX DEPOSIT / MAX MINT
    //////////////////////////////////////////////////////////////*/

    function testSFVault_MaxDeposit_UncappedWhenTVLCapZero() public {
        vm.prank(takadao);
        vault.setTVLCap(0);

        uint256 max0 = vault.maxDeposit(user);
        assertGt(max0, 1e30); // should be effectively uncapped
    }

    function testSFVault_MaxDeposit_ZeroWhenCapReached() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

        uint256 cap = 500_000;

        vm.prank(takadao);
        vault.setTVLCap(cap);

        _prepareUser(user, cap);
        vm.prank(user);
        vault.deposit(cap, user);

        assertEq(vault.maxDeposit(user), 0);
    }

    function testSFVault_MaxDeposit_RespectsTVLCap_NoFee() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

        uint256 cap = 1_000_000;

        vm.prank(takadao);
        vault.setTVLCap(cap);

        assertEq(vault.maxDeposit(user), cap);

        uint256 depositAmount = cap / 2;
        _prepareUser(user, depositAmount);
        vm.prank(user);
        vault.deposit(depositAmount, user);

        assertEq(vault.maxDeposit(user), cap - depositAmount);
    }

    function testSFVault_MaxDeposit_ReturnsZeroForNonMembers() public view {
        assertEq(vault.maxDeposit(address(this)), 0);
    }

    function testSFVault_MaxDeposit_AdjustsForManagementFee_WhenCapped() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

        uint256 cap = 1_000_000;
        uint16 mgmtBPS = 1000; // 10%

        vm.prank(takadao);
        vault.setTVLCap(cap);

        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        // With fee, maxDeposit should return the gross amount user can send s.t. net fits in cap
        uint256 expectedGross = Math.mulDiv(cap, MAX_BPS, (MAX_BPS - mgmtBPS));
        assertEq(vault.maxDeposit(user), expectedGross);

        // deposit at maxDeposit should pass
        _prepareUser(user, expectedGross);
        vm.prank(user);
        vault.deposit(expectedGross, user);

        assertEq(vault.totalAssets(), cap); // net in vault should hit cap
        assertEq(vault.maxDeposit(user), 0);
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

    function testSFVault_MaxMint_ReturnsZeroForNonMembersUsesMaxDepositAndPreviewDeposit() public view {
        assertEq(vault.maxMint(address(this)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                           PREVIEW DEPOSIT / MINT
    //////////////////////////////////////////////////////////////*/

    function testSFVault_PreviewDeposit_ZeroAssets_ReturnsZero() public view {
        assertEq(vault.previewDeposit(0), 0);
    }

    function testSFVault_PreviewDeposit_WithFee_UsesNetAssets() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

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
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

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
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

        vm.prank(takadao);
        vault.setFeeConfig(0, 0, 0);

        uint256 shares = 123_456;
        assertEq(vault.previewMint(shares), vault.convertToAssets(shares));
    }

    function testSFVault_PreviewMint_WithFee_AddsCeilFee() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

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

    function testSFVault_Deposit_RevertsIfNonMember() public {
        vm.expectRevert(SFVault.SFVault__NotAMember.selector);
        vault.deposit(0, address(this));
    }

    function testSFVault_Deposit_RevertsOnZeroAssets() public {
        vm.expectRevert(SFVault.SFVault__ZeroAssets.selector);
        vm.prank(user);
        vault.deposit(0, user);
    }

    function testSFVault_Deposit_RevertsWhenExceedsCap() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

        uint256 cap = 100_000;

        vm.prank(takadao);
        vault.setTVLCap(cap);

        _prepareUser(user, cap + 1);

        vm.prank(user);
        vm.expectRevert(SFVault.SFVault__ExceedsMaxDeposit.selector);
        vault.deposit(cap + 1, user);
    }

    function testSFVault_Deposit_TakesManagementFeeAndMintsNetShares() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

        uint16 mgmtBPS = 500; // 5%
        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        uint256 amount = 1_000_000;
        _prepareUser(user, amount);

        uint256 feeAssets = (amount * mgmtBPS) / MAX_BPS;
        uint256 netAssets = amount - feeAssets;

        vm.prank(user);
        uint256 sharesOut = vault.deposit(amount, user);

        assertEq(sharesOut, vault.convertToShares(netAssets));
        assertEq(asset.balanceOf(address(vault)), netAssets);
        assertEq(asset.balanceOf(feeRecipient), feeAssets);
        assertEq(vault.totalAssets(), netAssets);
        assertEq(vault.balanceOf(user), sharesOut);
    }

    function testSFVault_Deposit_SkipsFeeIfRecipientZero() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

        uint16 mgmtBPS = 500; // 5%
        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        _mockFeeRecipient(address(0));

        uint256 amount = 1_000_000;
        _prepareUser(user, amount);

        vm.prank(user);
        uint256 sharesOut = vault.deposit(amount, user);

        assertEq(asset.balanceOf(address(vault)), amount);
        assertEq(vault.totalAssets(), amount);
        assertEq(sharesOut, vault.convertToShares(amount));
    }

    function testSFVault_Deposit_RevertsWhenNetSharesZero() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

        vm.prank(takadao);
        vault.setFeeConfig(0, 0, 0);

        uint256 seed = 1_000_000;
        _prepareUser(user, seed);
        vm.prank(user);
        vault.deposit(seed, user);

        // Ensure cap won't block the deposit.
        // We want: totalAssets after donation == seed + 1, and still allow depositing 1.
        vm.prank(takadao);
        vault.setTVLCap(seed + 2);

        // Small donation is enough to make convertToShares(1) round down to 0
        _donateToVault(1);

        _prepareUser(user, 1);
        vm.prank(user);
        vm.expectRevert(SFVault.SFVault__ZeroShares.selector);
        vault.deposit(1, user);
    }

    /*//////////////////////////////////////////////////////////////
                                  MINT
    //////////////////////////////////////////////////////////////*/

    function testSFVault_Mint_RevertsIfNonMember() public {
        vm.expectRevert(SFVault.SFVault__NotAMember.selector);
        vault.mint(0, address(this));
    }

    function testSFVault_Mint_RevertsOnZeroShares() public {
        vm.expectRevert(SFVault.SFVault__ZeroShares.selector);
        vm.prank(user);
        vault.mint(0, user);
    }

    function testSFVault_Mint_TakesManagementFeeAndReturnsGrossAssets() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

        uint16 mgmtBPS = 500; // 5%
        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        uint256 shares = 1_000_000;

        uint256 grossAssets = vault.previewMint(shares);
        _prepareUser(user, grossAssets);
        vm.prank(user);
        uint256 spent = vault.mint(shares, user);
        assertEq(spent, grossAssets);

        // vault keeps netAssets == convertToAssets(shares) when supply was 0 (1:1)
        uint256 netAssets = vault.convertToAssets(shares);

        assertEq(asset.balanceOf(address(vault)), netAssets);
        assertEq(vault.balanceOf(user), shares);
        assertEq(vault.totalAssets(), netAssets);
        assertEq(asset.balanceOf(feeRecipient), grossAssets - netAssets);
    }

    function testSFVault_Mint_RevertsWhenExceedsCap() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(mock), ProtocolAddressType.Protocol);

        uint16 mgmtBPS = 500; // 5%
        uint256 cap = 100_000;

        vm.prank(takadao);
        vault.setTVLCap(cap);

        vm.prank(takadao);
        vault.setFeeConfig(mgmtBPS, 0, 0);

        // Mint shares requiring > cap net will revert due to grossAssets > maxDeposit
        uint256 shares = cap + 1;
        uint256 grossAssets = vault.previewMint(shares);
        _prepareUser(user, grossAssets);
        vm.prank(user);
        vm.expectRevert(SFVault.SFVault__ExceedsMaxDeposit.selector);
        vault.mint(shares, user);
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
}
