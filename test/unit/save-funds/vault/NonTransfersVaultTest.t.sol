// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFVault} from "test/utils/05-DeploySFVault.s.sol";
import {DeploySFAndIFCircuitBreaker} from "test/utils/08-DeployCircuitBreaker.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {SFAndIFCircuitBreaker} from "contracts/breakers/SFAndIFCircuitBreaker.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract NonTransfersVaultTest is Test {
    DeployManagers internal managersDeployer;
    DeploySFVault internal vaultDeployer;
    DeploySFAndIFCircuitBreaker internal circuitBreakerDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault internal vault;
    SFAndIFCircuitBreaker internal circuitBreaker;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;

    IERC20 internal asset;
    address internal takadao; // operator
    address internal feeRecipient;
    address internal backend;
    address internal pauser = makeAddr("pauser");
    address internal user = makeAddr("user");

    uint256 internal constant ONE_USDC = 1e6;

    // We avoid depending on the CB contract ABI here; just mock selectors if needed.
    bytes4 internal constant HOOK_WITHDRAW_SEL = bytes4(keccak256("hookWithdraw(address,address,uint256)"));
    bytes4 internal constant HOOK_REDEEM_SEL = bytes4(keccak256("hookRedeem(address,address,uint256)"));

    function setUp() public {
        managersDeployer = new DeployManagers();
        vaultDeployer = new DeploySFVault();
        circuitBreakerDeployer = new DeploySFAndIFCircuitBreaker();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();
        (address operatorAddr,,, address backendAddr,,,) = addressesAndRoles.run(_addrMgr, config, address(_modMgr));

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        takadao = operatorAddr;
        backend = backendAddr;

        // Deploy vault first or second doesn't matter IF you protect it afterwards.
        // Keeping your order, but we will protect after both exist.
        circuitBreaker = circuitBreakerDeployer.run(_addrMgr);

        vault = vaultDeployer.run(addrMgr);
        asset = IERC20(vault.asset());

        feeRecipient = makeAddr("feeRecipient");

        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);
        addrMgr.addProtocolAddress("PROTOCOL__CIRCUIT_BREAKER", address(circuitBreaker), ProtocolAddressType.Admin);
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN, true);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);

        vm.prank(takadao);
        circuitBreaker.setGuards(address(vault), 0, 0, 0, true);

        vm.prank(backend);
        vault.registerMember(user);
    }

    /*//////////////////////////////////////////////////////////////
                         NON-TRANSFERABLE SHARES
    //////////////////////////////////////////////////////////////*/

    function testSFVault_SharesAreNonTransferable_TransferReverts() public {
        uint256 amount = 1_000_000;
        _prepareUser(user, amount);

        vm.prank(user);
        vault.deposit(amount, user);

        uint256 bal = vault.balanceOf(user);
        assertGt(bal, 0);

        vm.expectRevert(SFVault.SFVault__NonTransferableShares.selector);
        vault.transfer(makeAddr("bob"), bal);
    }

    function testSFVault_SharesAreNonTransferable_RedeemBurnAllowed() public {
        uint256 amount = 1_000_000;
        _prepareUser(user, amount);

        vm.prank(user);
        vault.deposit(amount, user);

        uint256 shares = vault.balanceOf(user);
        assertGt(shares, 0);

        vm.prank(user);
        uint256 assetsOut = vault.redeem(shares, user, user);

        assertEq(assetsOut, amount); // mgmt fee default 0 in this test
        assertEq(vault.balanceOf(user), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _prepareUser(address _user, uint256 amount) internal {
        deal(address(asset), _user, amount);
        vm.prank(_user);
        asset.approve(address(vault), type(uint256).max);
    }
}
