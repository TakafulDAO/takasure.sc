// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";

import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFVault} from "test/utils/05-DeploySFVault.s.sol";
import {DeploySFStrategyAggregator} from "test/utils/06-DeploySFStrategyAggregator.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";

import {StrategyConfig, SubStrategy} from "contracts/types/Strategies.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";

import {SFStrategyAggregatorHandler} from "test/helpers/handlers/SFStrategyAggregatorHandler.sol";

contract SFStrategyAggregatorInvariantTest is StdInvariant, Test {
    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    AddressManager internal addrMgr;
    ModuleManager internal modMgr;
    IERC20 internal asset;

    address internal takadao; // OPERATOR
    address internal pauser = makeAddr("pauser");

    SFStrategyAggregatorHandler internal handler;

    uint256 internal constant MAX_BPS = 10_000;

    function setUp() public {
        DeployManagers managersDeployer = new DeployManagers();
        DeploySFVault vaultDeployer = new DeploySFVault();
        DeploySFStrategyAggregator aggregatorDeployer = new DeploySFStrategyAggregator();
        AddAddressesAndRoles roles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();
        (address operatorAddr,,,,,,) = roles.run(_addrMgr, config, address(_modMgr));

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        takadao = operatorAddr;

        vault = vaultDeployer.run(addrMgr);
        asset = IERC20(vault.asset());

        aggregator = aggregatorDeployer.run(addrMgr, asset, address(vault));

        // fee recipient often required elsewhere; keep consistent
        address feeRecipient = makeAddr("feeRecipient");
        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", feeRecipient, ProtocolAddressType.Admin);

        // register the vault for aggregator's onlyContract("PROTOCOL__SF_VAULT") check
        vm.startPrank(addrMgr.owner());
        if (!addrMgr.hasName("PROTOCOL__SF_VAULT", address(vault))) {
            addrMgr.addProtocolAddress("PROTOCOL__SF_VAULT", address(vault), ProtocolAddressType.Admin);
        }
        vm.stopPrank();

        // pause guardian setup
        vm.startPrank(addrMgr.owner());
        addrMgr.createNewRole(Roles.PAUSE_GUARDIAN);
        addrMgr.proposeRoleHolder(Roles.PAUSE_GUARDIAN, pauser);
        vm.stopPrank();
        vm.prank(pauser);
        addrMgr.acceptProposedRole(Roles.PAUSE_GUARDIAN);

        handler = new SFStrategyAggregatorHandler(aggregator, asset, address(vault), takadao, pauser);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.opSetConfig.selector;
        selectors[1] = handler.opAddSubStrategy.selector;
        selectors[2] = handler.opUpdateSubStrategy.selector;
        selectors[3] = handler.opEmergencyExit.selector;
        selectors[4] = handler.opHarvest.selector;
        selectors[5] = handler.opRebalance.selector;
        selectors[6] = handler.opPause.selector;
        selectors[7] = handler.opUnpause.selector;
        selectors[8] = handler.vaultDeposit.selector;
        selectors[9] = handler.vaultWithdraw.selector;
        selectors[10] = handler.seedStrategyBalance.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                                INVARIANTS
    //////////////////////////////////////////////////////////////*/

    function invariant_Aggregator_TotalWeightIsInBoundsAndMatchesActiveSum() public view {
        SubStrategy[] memory subs = aggregator.getSubStrategies();

        uint256 sumActive;
        for (uint256 i; i < subs.length; i++) {
            // no zero strategy addresses stored
            assertTrue(address(subs[i].strategy) != address(0));

            // weights always within bps range
            assertTrue(subs[i].targetWeightBPS <= MAX_BPS);

            if (subs[i].isActive) sumActive += subs[i].targetWeightBPS;
        }

        // totalTargetWeightBPS should be the sum of ACTIVE weights
        assertEq(sumActive, aggregator.totalTargetWeightBPS());
        assertTrue(aggregator.totalTargetWeightBPS() <= MAX_BPS);
    }

    function invariant_Aggregator_SubStrategiesAreUnique() public view {
        SubStrategy[] memory subs = aggregator.getSubStrategies();

        for (uint256 i; i < subs.length; i++) {
            for (uint256 j = i + 1; j < subs.length; j++) {
                assertTrue(address(subs[i].strategy) != address(subs[j].strategy));
            }
        }
    }

    function invariant_Aggregator_TotalAssetsEqualsSumOfActiveStrategies() public view {
        // totalAssets() includes idle funds held by the aggregator + all child strategies (active or inactive)
        SubStrategy[] memory subs = aggregator.getSubStrategies();

        uint256 strategiesSum;
        for (uint256 i; i < subs.length; i++) {
            strategiesSum += ISFStrategy(address(subs[i].strategy)).totalAssets();
        }

        uint256 idle = asset.balanceOf(address(aggregator));

        assertEq(aggregator.positionValue(), strategiesSum);
        assertEq(aggregator.totalAssets(), idle + strategiesSum);
    }

    function invariant_Aggregator_MaxWithdrawEqualsTotalAssets() public view {
        assertEq(aggregator.maxWithdraw(), aggregator.totalAssets());
    }

    function invariant_Aggregator_ConfigAssetAndVaultStable() public view {
        StrategyConfig memory cfg = aggregator.getConfig();

        assertEq(cfg.asset, address(asset));
        assertEq(cfg.vault, address(vault));
        assertEq(cfg.paused, aggregator.paused());
    }
}
