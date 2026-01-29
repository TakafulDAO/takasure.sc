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
import {RecorderSubStrategy} from "test/mocks/MockSFStrategy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {SubStrategy} from "contracts/types/Strategies.sol";

contract AccessAndSettersAggregatorTest is Test {
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

        aggregator = aggregatorDeployer.run(addrMgr, asset, address(vault));

        // Fee recipient required by SFVault; not strictly needed for aggregator itself but kept consistent with other setup.
        feeRecipient = makeAddr("feeRecipient");
        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("SF_VAULT_FEE_RECIPIENT", feeRecipient, ProtocolAddressType.Admin);

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
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN, true);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);
    }

    function testAggregator_setConfig_RevertsForNonOperator(address caller) public {
        vm.assume(caller != takadao);

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.setConfig(bytes("x"));
    }

    function testAggregator_setConfig_AddsNewStrategies_ThenUpdatesExisting() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        RecorderSubStrategy s2 = new RecorderSubStrategy(asset);

        {
            address[] memory strategies = new address[](2);
            uint16[] memory weights = new uint16[](2);
            bool[] memory actives = new bool[](2);

            strategies[0] = address(s1);
            strategies[1] = address(s2);
            weights[0] = 6000;
            weights[1] = 3000;
            actives[0] = true;
            actives[1] = true;

            vm.prank(takadao);
            aggregator.setConfig(abi.encode(strategies, weights, actives));

            assertEq(aggregator.totalTargetWeightBPS(), 9000);
        }

        // Call setConfig again to take the "existed == true" update branch
        {
            address[] memory strategies2 = new address[](2);
            uint16[] memory weights2 = new uint16[](2);
            bool[] memory actives2 = new bool[](2);

            strategies2[0] = address(s1);
            strategies2[1] = address(s2);
            weights2[0] = 8000;
            weights2[1] = 0;
            actives2[0] = true;
            actives2[1] = false; // inactive => recompute sum-only-active branch

            vm.prank(takadao);
            aggregator.setConfig(abi.encode(strategies2, weights2, actives2));

            // only active weights count
            assertEq(aggregator.totalTargetWeightBPS(), 8000);
        }
    }

    function testAggregator_setConfig_RevertsOnEmptyConfig() public {
        address[] memory strategies = new address[](0);
        uint16[] memory weights = new uint16[](0);
        bool[] memory actives = new bool[](0);

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__InvalidConfig.selector);
        aggregator.setConfig(abi.encode(strategies, weights, actives));
    }

    function testAggregator_setConfig_RevertsOnLengthMismatch() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);

        address[] memory strategies = new address[](2);
        uint16[] memory weights = new uint16[](2);
        bool[] memory actives = new bool[](1);

        strategies[0] = address(s1);
        weights[0] = 1;
        weights[1] = 2;
        actives[0] = true;

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__InvalidConfig.selector);
        aggregator.setConfig(abi.encode(strategies, weights, actives));
    }

    function testAggregator_setConfig_RevertsOnDuplicateStrategy() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);

        address[] memory strategies = new address[](2);
        uint16[] memory weights = new uint16[](2);
        bool[] memory actives = new bool[](2);

        strategies[0] = address(s1);
        strategies[1] = address(s1); // duplicate
        weights[0] = 1;
        weights[1] = 2;
        actives[0] = true;
        actives[1] = true;

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__DuplicateStrategy.selector);
        aggregator.setConfig(abi.encode(strategies, weights, actives));
    }

    function testAggregator_setConfig_RevertsOnWeightTooHigh() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);

        address[] memory strategies = new address[](1);
        uint16[] memory weights = new uint16[](1);
        bool[] memory actives = new bool[](1);

        strategies[0] = address(s1);
        weights[0] = uint16(MAX_BPS + 1);
        actives[0] = true;

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__InvalidTargetWeightBPS.selector);
        aggregator.setConfig(abi.encode(strategies, weights, actives));
    }

    function testAggregator_setConfig_RevertsWhenStrategyNotAContract() public {
        address eoa = makeAddr("eoa");

        address[] memory strategies = new address[](1);
        uint16[] memory weights = new uint16[](1);
        bool[] memory actives = new bool[](1);

        strategies[0] = eoa;
        weights[0] = 1;
        actives[0] = true;

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__StrategyNotAContract.selector);
        aggregator.setConfig(abi.encode(strategies, weights, actives));
    }
}

