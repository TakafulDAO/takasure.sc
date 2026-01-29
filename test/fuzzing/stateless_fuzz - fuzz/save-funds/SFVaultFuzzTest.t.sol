// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFVault} from "test/utils/05-DeploySFVault.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";

import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract SFVaultFuzzTest is Test {
    DeployManagers internal managersDeployer;
    DeploySFVault internal vaultDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault internal vault;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;

    IERC20 internal asset;

    address internal takadao; // OPERATOR
    address internal feeRecipient;
    address internal pauser = makeAddr("pauser"); // PAUSE_GUARDIAN

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
        asset = IERC20(vault.asset());

        feeRecipient = makeAddr("feeRecipient");

        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);

        // Ensure PAUSE_GUARDIAN exists and is held by `pauser`
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN, true);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ: OPERATOR ONLY
    //////////////////////////////////////////////////////////////*/

    function testFuzzSFVault_SetTVLCap_RevertsIfCallerNotOperator(address caller, uint256 newCap) public {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        vm.prank(caller);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.setTVLCap(newCap);
    }

    function testFuzzSFVault_WhitelistToken_RevertsIfCallerNotOperator(address caller, address token) public {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        vm.prank(caller);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.whitelistToken(token);
    }

    function testFuzzSFVault_WhitelistTokenWithCap_RevertsIfCallerNotOperator(
        address caller,
        address token,
        uint16 hardCapBPS
    ) public {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        vm.prank(caller);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.whitelistTokenWithCap(token, hardCapBPS);
    }

    function testFuzzSFVault_RemoveTokenFromWhitelist_RevertsIfCallerNotOperator(address caller, address token) public {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        vm.prank(caller);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.removeTokenFromWhitelist(token);
    }

    function testFuzzSFVault_SetTokenHardCap_RevertsIfCallerNotOperator(address caller, address token, uint16 newCapBPS)
        public
    {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        vm.prank(caller);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.setTokenHardCap(token, newCapBPS);
    }

    function testFuzzSFVault_SetAggregator_RevertsIfCallerNotOperator(address caller, address newAggregator) public {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        vm.prank(caller);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.setAggregator(ISFStrategy(newAggregator));
    }

    function testFuzzSFVault_SetFeeConfig_RevertsIfCallerNotOperator(
        address caller,
        uint16 mgmtBPS,
        uint16 perfBPS,
        uint16 hurdleBPS
    ) public {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        vm.prank(caller);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.setFeeConfig(mgmtBPS, perfBPS, hurdleBPS);
    }

    function testFuzzSFVault_TakeFees_RevertsIfCallerNotOperator(address caller) public {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        vm.prank(caller);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.takeFees();
    }

    function testFuzzSFVault_UpgradeTo_RevertsIfCallerNotOperator(address caller) public {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        SFVault newImpl = new SFVault();

        vm.prank(caller);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.upgradeToAndCall(address(newImpl), "");
    }

    function testFuzzSFVault_UpgradeToAndCall_RevertsIfCallerNotOperator(address caller, bytes calldata data) public {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        SFVault newImpl = new SFVault();

        // Any calldata is fine; revert should be authorization anyway.
        vm.prank(caller);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.upgradeToAndCall(address(newImpl), data);
    }

    /*//////////////////////////////////////////////////////////////
                      FUZZ: PAUSE_GUARDIAN ONLY
    //////////////////////////////////////////////////////////////*/

    function testFuzzSFVault_Pause_RevertsIfCallerNotPauseGuardian(address caller) public {
        vm.assume(!addrMgr.hasRole(Roles.PAUSE_GUARDIAN, caller));

        vm.prank(caller);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.pause();
    }

    function testFuzzSFVault_Unpause_RevertsIfCallerNotPauseGuardian(address caller) public {
        vm.assume(!addrMgr.hasRole(Roles.PAUSE_GUARDIAN, caller));

        vm.prank(caller);
        vm.expectRevert(SFVault.SFVault__NotAuthorizedCaller.selector);
        vault.unpause();
    }
}
