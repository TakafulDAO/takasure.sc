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
import {SFStrategyAggregatorLens} from "contracts/saveFunds/SFStrategyAggregatorLens.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {TestSubStrategy} from "test/mocks/MockSFStrategy.sol";
import {MockValuator} from "test/mocks/MockValuator.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {StrategyConfig} from "contracts/types/Strategies.sol";

contract GettersAggregatorTest is Test {
    using SafeERC20 for IERC20;

    DeployManagers internal managersDeployer;
    DeploySFVault internal vaultDeployer;
    DeploySFStrategyAggregator internal aggregatorDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFStrategyAggregatorLens internal aggregatorLens;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;

    IERC20 internal asset;

    address internal takadao; // operator
    address internal feeRecipient;
    address internal pauser = makeAddr("pauser");
    MockValuator internal valuator;

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

        aggregator = aggregatorDeployer.run(addrMgr, asset);
        aggregatorLens = new SFStrategyAggregatorLens();

        // Fee recipient required by SFVault; not strictly needed for aggregator itself but kept consistent with other setup.
        feeRecipient = makeAddr("feeRecipient");
        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);
        valuator = new MockValuator();
        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("HELPER__SF_VALUATOR", address(valuator), ProtocolAddressType.Admin);

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

    function testAggregator_getConfig_ReturnsExpected() public {
        StrategyConfig memory cfg = aggregatorLens.getConfig(address(aggregator));

        assertEq(cfg.asset, address(asset));
        assertEq(cfg.vault, address(vault));
        assertEq(cfg.pool, address(0));
        assertEq(cfg.paused, aggregator.paused());

        vm.prank(pauser);
        aggregator.pause();

        StrategyConfig memory cfg2 = aggregatorLens.getConfig(address(aggregator));
        assertTrue(cfg2.paused);
    }

    function testAggregator_totalAssets_SumsOnlyActive() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 5000);
        aggregator.addSubStrategy(address(s2), 5000);
        aggregator.updateSubStrategy(address(s2), 0, false); // inactive
        vm.stopPrank();

        deal(address(asset), address(s1), 111);
        deal(address(asset), address(s2), 999);

        assertEq(aggregator.totalAssets(), 1110);
        assertEq(aggregatorLens.positionValue(address(aggregator)), 1110);
    }

    function testAggregator_maxWithdraw_EqualsTotalAssets() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        vm.prank(takadao);
        aggregator.addSubStrategy(address(s1), 10_000);

        deal(address(asset), address(s1), 777);

        assertEq(aggregator.maxWithdraw(), 777);
    }

    function testAggregator_getPositionDetails_EncodesArrays() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 6000);
        aggregator.addSubStrategy(address(s2), 3000);
        aggregator.updateSubStrategy(address(s2), 0, false);
        vm.stopPrank();

        bytes memory details = aggregatorLens.getPositionDetails(address(aggregator));
        (address[] memory strategies, uint16[] memory weights, bool[] memory actives) =
            abi.decode(details, (address[], uint16[], bool[]));

        assertEq(strategies.length, 2);
        assertEq(weights.length, 2);
        assertEq(actives.length, 2);

        assertEq(strategies[0], address(s1));
        assertEq(weights[0], 6000);
        assertTrue(actives[0]);

        assertEq(strategies[1], address(s2));
        assertEq(weights[1], 0);
        assertFalse(actives[1]);
    }
}
