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
import {
    TestSubStrategy,
    NoAssetStrategy,
    ShortReturnAssetStrategy,
    WrongAssetStrategy
} from "test/mocks/MockSFStrategy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import { SubStrategy} from "contracts/types/Strategies.sol";

contract SubStratsAggregatorTest is Test {
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
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();

        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);
    }

    function _emptyPerStrategyData() internal pure returns (bytes memory) {
        return abi.encode(new address[](0), new bytes[](0));
    }

    function testAggregator_addSubStrategy_AddsAndDefaultsActive() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);

        vm.prank(takadao);
        aggregator.addSubStrategy(address(s1), 6000);

        assertEq(aggregator.totalTargetWeightBPS(), 6000);

        SubStrategy[] memory list = aggregator.getSubStrategies();
        assertEq(list.length, 1);
        assertEq(address(list[0].strategy), address(s1));
        assertEq(list[0].targetWeightBPS, 6000);
        assertTrue(list[0].isActive);
    }

    function testAggregator_addSubStrategy_RevertsOnZeroAddress() public {
        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAddressZero.selector);
        aggregator.addSubStrategy(address(0), 1);
    }

    function testAggregator_addSubStrategy_RevertsWhenAlreadyExists() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 1000);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__SubStrategyAlreadyExists.selector);
        aggregator.addSubStrategy(address(s1), 1);
        vm.stopPrank();
    }

    function testAggregator_addSubStrategy_RevertsWhenTotalWeightExceedsMax() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 9000);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__InvalidTargetWeightBPS.selector);
        aggregator.addSubStrategy(address(s2), 2000);
        vm.stopPrank();
    }

    function testAggregator_updateSubStrategy_UpdatesWeightAndActiveAndTotal() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 5000);
        aggregator.addSubStrategy(address(s2), 5000);
        vm.stopPrank();

        assertEq(aggregator.totalTargetWeightBPS(), 10_000);

        // deactivate s1 -> total should drop to 5000
        vm.prank(takadao);
        aggregator.updateSubStrategy(address(s1), 5000, false);
        assertEq(aggregator.totalTargetWeightBPS(), 5000);

        // update s2 weight upward while active -> total becomes 8000
        vm.prank(takadao);
        aggregator.updateSubStrategy(address(s2), 8000, true);
        assertEq(aggregator.totalTargetWeightBPS(), 8000);

        SubStrategy[] memory list = aggregator.getSubStrategies();
        assertEq(list.length, 2);
        // order preserved
        assertFalse(list[0].isActive);
        assertEq(list[1].targetWeightBPS, 8000);
        assertTrue(list[1].isActive);
    }

    function testAggregator_updateSubStrategy_RevertsIfNotFound() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__SubStrategyNotFound.selector);
        aggregator.updateSubStrategy(address(s1), 1, true);
    }

    function testAggregator_updateSubStrategy_RevertsIfTotalWouldExceedMax() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 5000);
        aggregator.addSubStrategy(address(s2), 5000);
        // try to increase s1 to 6000 while still active -> would go 11000
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__InvalidTargetWeightBPS.selector);
        aggregator.updateSubStrategy(address(s1), 6000, true);
        vm.stopPrank();
    }

    function testAggregator_updateSubStrategy_RevertsOnZeroAddress() public {
        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAddressZero.selector);
        aggregator.updateSubStrategy(address(0), 1, true);
    }

    function testAggregator_addSubStrategy_RevertsWhenNoAssetFunction() public {
        NoAssetStrategy s = new NoAssetStrategy();

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__InvalidStrategyAsset.selector);
        aggregator.addSubStrategy(address(s), 1000);
    }

    function testAggregator_addSubStrategy_RevertsWhenAssetReturnTooShort() public {
        ShortReturnAssetStrategy s = new ShortReturnAssetStrategy();

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__InvalidStrategyAsset.selector);
        aggregator.addSubStrategy(address(s), 1000);
    }

    function testAggregator_addSubStrategy_RevertsWhenAssetMismatch() public {
        WrongAssetStrategy s = new WrongAssetStrategy(makeAddr("not-underlying"));

        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__InvalidStrategyAsset.selector);
        aggregator.addSubStrategy(address(s), 1000);
    }
}

