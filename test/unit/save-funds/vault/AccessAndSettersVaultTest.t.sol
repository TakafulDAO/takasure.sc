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

contract AccessAndSettersVaultTest is Test {
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

        vault = vaultDeployer.run(addrMgr);
        asset = IERC20(vault.asset());

        feeRecipient = makeAddr("feeRecipient");

        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN, true);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);
    }

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

    function testSFVault_SetTVLCap_UpdatesValue() public {
        uint256 newCap = 1_000_000;

        vm.prank(takadao);
        vault.setTVLCap(newCap);

        assertEq(vault.TVLCap(), newCap);
    }

    function testSFVault_SetAggregator_UpdatesValue() public {
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());

        vm.prank(takadao);
        vault.setAggregator(ISFStrategy(address(mock)));

        assertEq(address(vault.aggregator()), address(mock));
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

    function testSFVault_UpgradeTo_Works() public {
        SFVault newImpl = new SFVault();

        vm.prank(takadao);
        vault.upgradeToAndCall(address(newImpl), "");

        // sanity: state should remain accessible
        vault.totalAssets();
    }

    function testSFVault_setERC721ApprovalForAll_OnlyOperator_AndMakesCall() public {
        address attacker = makeAddr("attacker");
        MockERC721ApprovalForAll nft = new MockERC721ApprovalForAll();
        address op = makeAddr("op");

        vm.prank(attacker);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.setERC721ApprovalForAll(address(nft), op, true);

        vm.expectCall(address(nft), abi.encodeWithSelector(IERC721.setApprovalForAll.selector, op, true));
        vm.prank(takadao);
        vault.setERC721ApprovalForAll(address(nft), op, true);

        // msg.sender in the mock is the vault (proxy) itself
        assertTrue(nft.isApprovedForAll(address(vault), op));
    }
}
