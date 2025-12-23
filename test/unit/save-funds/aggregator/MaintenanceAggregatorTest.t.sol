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
import {TestSubStrategy, RecorderSubStrategy} from "test/mocks/MockSFStrategy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {StrategyConfig, SubStrategy} from "contracts/types/Strategies.sol";

contract MaintenanceAggregatorTest is Test {
    using SafeERC20 for IERC20;

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
    address internal feeRecipient;
    address internal pauser = makeAddr("pauser");

    uint256 internal constant MAX_BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

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

        aggregator = aggregatorDeployer.run(addrMgr, asset, 100_000, address(vault));

        // Fee recipient required by SFVault; not strictly needed for aggregator itself but kept consistent with other setup.
        feeRecipient = makeAddr("feeRecipient");
        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);

        // Ensure the vault is recognized as "PROTOCOL__SF_VAULT" for onlyContract checks.
        vm.startPrank(addrMgr.owner());
        if (!addrMgr.hasName("PROTOCOL__SF_VAULT", address(vault))) {
            // If the name already exists with a different addr, this may revert; in that case tests that rely on onlyContract
            // will fail loudly (which is what we want).
            addrMgr.addProtocolAddress("PROTOCOL__SF_VAULT", address(vault), ProtocolAddressType.Admin);
        }
        vm.stopPrank();

        // Pause guardian role for pause/unpause coverage
        vm.startPrank(addrMgr.owner());
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);
    }

    function testAggregator_harvest_CallsOnlyActiveStrategies_OperatorAllowed() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 5000);
        aggregator.addSubStrategy(address(s2), 5000);
        aggregator.updateSubStrategy(address(s2), 5000, false); // inactive
        vm.stopPrank();

        vm.prank(takadao);
        aggregator.harvest(bytes(""));

        assertEq(s1.harvestCount(), 1);
        assertEq(s2.harvestCount(), 0);
    }

    function testAggregator_harvest_RevertsForRandomCaller(address caller) public {
        vm.assume(caller != takadao);

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.harvest(bytes(""));
    }

    function testAggregator_harvest_RevertsWhenPaused() public {
        vm.prank(pauser);
        aggregator.pause();

        vm.prank(takadao);
        vm.expectRevert(); // OZ Pausable error
        aggregator.harvest(bytes(""));
    }

    function testAggregator_rebalance_CallsOnlyActiveStrategies_OperatorAllowed() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 5000);
        aggregator.addSubStrategy(address(s2), 5000);
        aggregator.updateSubStrategy(address(s2), 5000, false); // inactive
        vm.stopPrank();

        vm.prank(takadao);
        aggregator.rebalance(bytes(""));

        assertEq(s1.rebalanceCount(), 1);
        assertEq(s2.rebalanceCount(), 0);
    }

    function testAggregator_rebalance_RevertsForRandomCaller(address caller) public {
        vm.assume(caller != takadao);

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.rebalance(bytes(""));
    }

    function testAggregator_rebalance_RevertsWhenPaused() public {
        vm.prank(pauser);
        aggregator.pause();

        vm.prank(takadao);
        vm.expectRevert(); // OZ Pausable error
        aggregator.rebalance(bytes(""));
    }

    function testAggregator_harvest_RevertsOnPerStrategyLengthMismatch() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        _addStrategy(address(s1), 10000, true);

        address[] memory strategies = new address[](1);
        bytes[] memory payloads = new bytes[](0); // mismatch

        strategies[0] = address(s1);

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__InvalidPerStrategyData.selector);
        aggregator.harvest(_encodePerStrategyData(strategies, payloads));
    }

    function testAggregator_harvest_RevertsOnUnknownPerStrategyDataStrategy() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        _addStrategy(address(s1), 10000, true);

        address unknown = makeAddr("unknown");

        address[] memory strategies = new address[](1);
        bytes[] memory payloads = new bytes[](1);

        strategies[0] = unknown; // not in set
        payloads[0] = hex"01";

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__UnknownPerStrategyDataStrategy.selector);
        aggregator.harvest(_encodePerStrategyData(strategies, payloads));
    }

    function testAggregator_harvest_RevertsOnDuplicatePerStrategyDataStrategy() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        _addStrategy(address(s1), 10000, true);

        address[] memory strategies = new address[](2);
        bytes[] memory payloads = new bytes[](2);

        strategies[0] = address(s1);
        strategies[1] = address(s1); // duplicate
        payloads[0] = hex"01";
        payloads[1] = hex"02";

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__DuplicatePerStrategyDataStrategy.selector);
        aggregator.harvest(_encodePerStrategyData(strategies, payloads));
    }

    function testAggregator_harvest_RevertsOnZeroAddressInPerStrategyData() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        _addStrategy(address(s1), 10000, true);

        address[] memory strategies = new address[](1);
        bytes[] memory payloads = new bytes[](1);

        strategies[0] = address(0);
        payloads[0] = hex"01";

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAddressZero.selector);
        aggregator.harvest(_encodePerStrategyData(strategies, payloads));
    }

    function testAggregator_harvest_WithAllowlist_CallsInactiveToo_AndPayloadMatches() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        RecorderSubStrategy s2 = new RecorderSubStrategy(asset);

        _addStrategy(address(s1), 6000, true);
        _addStrategy(address(s2), 3000, false); // inactive

        address[] memory strategies = new address[](2);
        bytes[] memory payloads = new bytes[](2);

        strategies[0] = address(s1);
        strategies[1] = address(s2);
        payloads[0] = hex"aa55";
        payloads[1] = hex"bb66";

        vm.prank(takadao);
        aggregator.harvest(_encodePerStrategyData(strategies, payloads));

        assertEq(s1.harvestCount(), 1);
        assertEq(s2.harvestCount(), 1); // IMPORTANT: harvest allowlist path does NOT check active

        assertEq(s1.lastHarvestDataHash(), keccak256(payloads[0]));
        assertEq(s2.lastHarvestDataHash(), keccak256(payloads[1]));
    }

    function testAggregator_rebalance_WithAllowlist_SkipsInactive() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        RecorderSubStrategy s2 = new RecorderSubStrategy(asset);

        _addStrategy(address(s1), 6000, true);
        _addStrategy(address(s2), 3000, false); // inactive

        address[] memory strategies = new address[](2);
        bytes[] memory payloads = new bytes[](2);

        strategies[0] = address(s1);
        strategies[1] = address(s2);
        payloads[0] = hex"11";
        payloads[1] = hex"22";

        vm.prank(takadao);
        aggregator.rebalance(_encodePerStrategyData(strategies, payloads));

        assertEq(s1.rebalanceCount(), 1);
        assertEq(s2.rebalanceCount(), 0); // rebalance allowlist path DOES check active
        assertEq(s1.lastRebalanceDataHash(), keccak256(payloads[0]));
    }

    function testAggregator_harvest_AllowsKeeperRole() public {
        // create & grant keeper
        address keeper = makeAddr("keeper");

        vm.startPrank(addrMgr.owner());
        addrMgr.createNewRole(Roles.KEEPER);
        addrMgr.proposeRoleHolder(Roles.KEEPER, keeper);
        vm.stopPrank();

        vm.prank(keeper);
        addrMgr.acceptProposedRole(Roles.KEEPER);

        // add one strategy so the "data.length == 0" path iterates + active check is evaluated
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        _addStrategy(address(s1), 10000, true);

        vm.prank(keeper);
        aggregator.harvest(bytes(""));

        assertEq(s1.harvestCount(), 1);
    }

    /*//////////////////////////////////////////////////////////////
                             Helpers
    //////////////////////////////////////////////////////////////*/

    function _encodePerStrategyData(address[] memory strategies, bytes[] memory payloads)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(strategies, payloads);
    }

    function _addStrategy(address s, uint16 w, bool active) internal {
        vm.prank(takadao);
        aggregator.addSubStrategy(s, w);

        if (!active) {
            vm.prank(takadao);
            aggregator.updateSubStrategy(s, w, false);
        }
    }
}

