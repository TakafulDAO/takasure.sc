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
import {MockValuator} from "test/mocks/MockValuator.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

contract SFStrategyAggregatorFuzzTest is Test {
    DeployManagers internal managersDeployer;
    DeploySFVault internal vaultDeployer;
    DeploySFStrategyAggregator internal aggregatorDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;

    IERC20 internal asset;
    address internal takadao; // OPERATOR
    address internal feeRecipient;
    address internal pauser = makeAddr("pauser"); // PAUSE_GUARDIAN
    MockValuator internal valuator;

    function setUp() public {
        managersDeployer = new DeployManagers();
        vaultDeployer = new DeploySFVault();
        aggregatorDeployer = new DeploySFStrategyAggregator();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();
        (address operatorAddr,,,,,,) = addressesAndRoles.run(_addrMgr, config, address(_modMgr));

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        takadao = operatorAddr;

        vault = vaultDeployer.run(addrMgr);
        asset = IERC20(vault.asset());
        aggregator = aggregatorDeployer.run(addrMgr, asset);

        feeRecipient = makeAddr("feeRecipient");
        valuator = new MockValuator();

        vm.startPrank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);
        addrMgr.addProtocolAddress("HELPER__SF_VALUATOR", address(valuator), ProtocolAddressType.Admin);

        // Ensure PAUSE_GUARDIAN exists and is held by `pauser`
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);
    }

    /*//////////////////////////////////////////////////////////////
                          FUZZ: OPERATOR ONLY
    //////////////////////////////////////////////////////////////*/

    function testFuzzAggregator_SetConfig_RevertsIfCallerNotOperator(address caller, bytes calldata cfg) public {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.setConfig(cfg);
    }

    function testFuzzAggregator_AddSubStrategy_RevertsIfCallerNotOperator(
        address caller,
        address strategy,
        uint16 weightBps
    ) public {
        vm.assume(strategy != address(0));
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.addSubStrategy(strategy, weightBps);
    }

    function testFuzzAggregator_UpdateSubStrategy_RevertsIfCallerNotOperator(
        address caller,
        address strategy,
        uint16 weightBps,
        bool isActive
    ) public {
        vm.assume(strategy != address(0));
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.updateSubStrategy(strategy, weightBps, isActive);
    }

    function testFuzzAggregator_EmergencyExit_RevertsIfCallerNotOperator(address caller, address receiver) public {
        vm.assume(receiver != address(0));
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.emergencyExit(receiver);
    }

    function testFuzzAggregator_UpgradeToAndCall_RevertsIfCallerNotOperator(address caller, bytes calldata data)
        public
    {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));

        SFStrategyAggregator newImpl = new SFStrategyAggregator();

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.upgradeToAndCall(address(newImpl), data);
    }

    /*//////////////////////////////////////////////////////////////
                        FUZZ: KEEPER OR OPERATOR
    //////////////////////////////////////////////////////////////*/

    function testFuzzAggregator_Harvest_RevertsIfCallerNotKeeperOrOperator(address caller, bytes calldata data) public {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));
        vm.assume(!addrMgr.hasRole(Roles.KEEPER, caller));

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.harvest(data);
    }

    function testFuzzAggregator_Rebalance_RevertsIfCallerNotKeeperOrOperator(address caller, bytes calldata data)
        public
    {
        vm.assume(!addrMgr.hasRole(Roles.OPERATOR, caller));
        vm.assume(!addrMgr.hasRole(Roles.KEEPER, caller));

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.rebalance(data);
    }

    /*//////////////////////////////////////////////////////////////
                      FUZZ: PAUSE_GUARDIAN ONLY
    //////////////////////////////////////////////////////////////*/

    function testFuzzAggregator_Pause_RevertsIfCallerNotPauseGuardian(address caller) public {
        vm.assume(!addrMgr.hasRole(Roles.PAUSE_GUARDIAN, caller));

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.pause();
    }

    function testFuzzAggregator_Unpause_RevertsIfCallerNotPauseGuardian(address caller) public {
        vm.assume(!addrMgr.hasRole(Roles.PAUSE_GUARDIAN, caller));

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.unpause();
    }

    /*//////////////////////////////////////////////////////////////
                      FUZZ: ONLY SF VAULT CONTRACT
    //////////////////////////////////////////////////////////////*/

    function testFuzzAggregator_Deposit_RevertsIfCallerNotVault(address caller, uint256 assetsIn) public {
        // Avoid hitting NotZeroAmount first
        uint256 assets = bound(assetsIn, 1, type(uint128).max);

        // onlyContract("PROTOCOL__SF_VAULT")
        vm.assume(!addrMgr.hasName("PROTOCOL__SF_VAULT", caller));

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.deposit(assets, bytes(""));
    }

    function testFuzzAggregator_Withdraw_RevertsIfCallerNotVault(address caller, uint256 assetsIn, address receiver)
        public
    {
        // Avoid receiver==0 and assets==0 reverts first
        vm.assume(receiver != address(0));
        uint256 assets = bound(assetsIn, 1, type(uint128).max);

        // onlyContract("PROTOCOL__SF_VAULT")
        vm.assume(!addrMgr.hasName("PROTOCOL__SF_VAULT", caller));

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.withdraw(assets, receiver, bytes(""));
    }
}
