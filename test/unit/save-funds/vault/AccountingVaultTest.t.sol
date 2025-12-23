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

contract AccountingVaultTest is Test {
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
    }

    function testSFVault_IdleAssets_StrategyAssets_TotalAssets_Accounting() public {
        uint256 amount = 1_000_000;
        address user = makeAddr("user");

        vm.prank(backend);
        vault.registerMember(user);

        _prepareUser(user, amount);
        vm.prank(user);
        vault.deposit(amount, user);

        assertEq(vault.strategyAssets(), 0);
        assertEq(vault.idleAssets(), asset.balanceOf(address(vault)));
        assertEq(vault.totalAssets(), vault.idleAssets());

        // attach mock strategy
        MockSFStrategy mock = new MockSFStrategy(address(vault), vault.asset());
        vm.prank(takadao);
        vault.setStrategy(ISFStrategy(address(mock)));

        // put assets into strategy (independent of vault; totalAssets() sums both)
        uint256 stratAssets = 500_000;
        deal(address(asset), user, stratAssets);
        vm.prank(user);
        asset.approve(address(mock), stratAssets);
        mock.setMaxTVL(type(uint256).max);
        mock.deposit(stratAssets, "");

        assertEq(vault.strategyAssets(), mock.totalAssets());
        assertEq(vault.totalAssets(), vault.idleAssets() + vault.strategyAssets());
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _prepareUser(address user, uint256 amount) internal {
        deal(address(asset), user, amount);
        vm.prank(user);
        asset.approve(address(vault), type(uint256).max);
    }
}
