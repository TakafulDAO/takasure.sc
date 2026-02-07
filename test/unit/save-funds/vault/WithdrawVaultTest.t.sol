// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFVault} from "test/utils/05-DeploySFVault.s.sol";
import {DeploySFStrategyAggregator} from "test/utils/06-DeploySFStrategyAggregator.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {TestSubStrategy} from "test/mocks/MockSFStrategy.sol";
import {MockValuator} from "test/mocks/MockValuator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract WithdrawVaultTest is Test {
    DeployManagers internal managersDeployer;
    DeploySFVault internal vaultDeployer;
    DeploySFStrategyAggregator internal aggregatorDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;

    IERC20 internal asset;
    address internal takadao; // operator
    address internal backend;
    address internal feeRecipient;
    address internal pauser = makeAddr("pauser");
    address internal user = makeAddr("user");
    MockValuator internal valuator;

    uint256 internal constant ONE_USDC = 1e6;

    function setUp() public {
        managersDeployer = new DeployManagers();
        vaultDeployer = new DeploySFVault();
        aggregatorDeployer = new DeploySFStrategyAggregator();
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
        aggregator = aggregatorDeployer.run(addrMgr, asset);

        feeRecipient = makeAddr("feeRecipient");
        valuator = new MockValuator();

        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);
        addrMgr.addProtocolAddress("HELPER__SF_VALUATOR", address(valuator), ProtocolAddressType.Admin);
        addrMgr.addProtocolAddress("PROTOCOL__SF_VAULT", address(vault), ProtocolAddressType.Protocol);
        addrMgr.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", address(aggregator), ProtocolAddressType.Protocol);
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);

        vm.prank(backend);
        vault.registerMember(user);
    }

    function testSFVault_withdraw_PullsFromStrategyWhenIdleInsufficient() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        vm.prank(takadao);
        aggregator.addSubStrategy(address(s1), 10_000);

        uint256 depositAmt = 1_000 * ONE_USDC;
        _prepareUser(user, depositAmt);
        vm.prank(user);
        vault.deposit(depositAmt, user);

        address[] memory strategies = new address[](1);
        bytes[] memory payloads = new bytes[](1);
        strategies[0] = address(s1);
        payloads[0] = bytes("");

        uint256 investAmt = 800 * ONE_USDC;
        vm.prank(takadao);
        vault.investIntoStrategy(investAmt, strategies, payloads);

        uint256 idleBefore = vault.idleAssets();
        assertEq(idleBefore, depositAmt - investAmt);
        assertEq(asset.balanceOf(address(s1)), investAmt);

        uint256 withdrawAmt = 500 * ONE_USDC;
        uint256 userBalBefore = asset.balanceOf(user);

        vm.prank(user);
        vault.withdraw(withdrawAmt, user, user);

        assertEq(asset.balanceOf(user), userBalBefore + withdrawAmt);
        assertEq(asset.balanceOf(address(s1)), investAmt - (withdrawAmt - idleBefore));
    }

    function _prepareUser(address _user, uint256 amount) internal {
        deal(address(asset), _user, amount);
        vm.prank(_user);
        asset.approve(address(vault), type(uint256).max);
    }
}
