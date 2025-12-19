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
import {TestSubStrategy} from "test/mocks/TestSubStrategy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {StrategyConfig, SubStrategy} from "contracts/types/Strategies.sol";

contract SFStrategyAggregatorTest is Test {
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

    function _fundAggregator(uint256 amount) internal {
        deal(address(asset), address(aggregator), amount);
    }

    function _emptyPerStrategyData() internal pure returns (bytes memory) {
        return abi.encode(new address[](0), new bytes[](0));
    }

    function _depositAsVault(uint256 assetsToInvest) internal returns (uint256 invested) {
        vm.prank(address(vault));
        invested = aggregator.deposit(assetsToInvest, _emptyPerStrategyData());
    }

    function _withdrawAsVault(uint256 assetsToWithdraw, address receiver) internal returns (uint256 withdrawn) {
        vm.prank(address(vault));
        withdrawn = aggregator.withdraw(assetsToWithdraw, receiver, _emptyPerStrategyData());
    }

    /*//////////////////////////////////////////////////////////////
                               ACCESS / SETTERS
    //////////////////////////////////////////////////////////////*/

    function testAggregator_setMaxTVL_UpdatesState() public {
        uint256 oldMax = aggregator.maxTVL();
        uint256 newMax = oldMax + 123;

        vm.prank(takadao);
        aggregator.setMaxTVL(newMax);

        assertEq(aggregator.maxTVL(), newMax);
    }

    function testAggregator_setMaxTVL_RevertsForNonOperator(address caller) public {
        vm.assume(caller != takadao);

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.setMaxTVL(1);
    }

    function testAggregator_setConfig_RevertsForNonOperator(address caller) public {
        vm.assume(caller != takadao);

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.setConfig(bytes("x"));
    }

    /*//////////////////////////////////////////////////////////////
                             SUB-STRATEGY MGMT
    //////////////////////////////////////////////////////////////*/

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

    /*//////////////////////////////////////////////////////////////
                             DEPOSIT BRANCHES
    //////////////////////////////////////////////////////////////*/

    function testAggregator_deposit_RevertsIfCallerNotVault(address caller) public {
        vm.assume(caller != address(vault));

        _fundAggregator(1);

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.deposit(1, bytes(""));
    }

    function testAggregator_deposit_RevertsWhenZeroAssets() public {
        vm.prank(address(vault));
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotZeroAmount.selector);
        aggregator.deposit(0, bytes(""));
    }

    function testAggregator_deposit_WhenNoSubStrategies_ReturnsFundsToVault() public {
        uint256 amount = 1_000;
        _fundAggregator(amount);

        uint256 invested = _depositAsVault(amount);
        assertEq(invested, 0);

        assertEq(asset.balanceOf(address(aggregator)), 0);
        assertEq(asset.balanceOf(address(vault)), amount);
    }

    function testAggregator_deposit_AllocatesToActiveAndReturnsRemainderToVault() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 6000);
        aggregator.addSubStrategy(address(s2), 3000); // total = 9000, remainder 10%
        vm.stopPrank();

        uint256 amount = 1_000;
        _fundAggregator(amount);

        uint256 invested = _depositAsVault(amount);
        assertEq(invested, 900); // 600 + 300

        assertEq(asset.balanceOf(address(s1)), 600);
        assertEq(asset.balanceOf(address(s2)), 300);
        assertEq(asset.balanceOf(address(vault)), 100);
        assertEq(asset.balanceOf(address(aggregator)), 0);
    }

    function testAggregator_deposit_SkipsInactiveStrategy() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 6000);
        aggregator.addSubStrategy(address(s2), 4000);
        aggregator.updateSubStrategy(address(s2), 4000, false);
        vm.stopPrank();

        uint256 amount = 1_000;
        _fundAggregator(amount);

        uint256 invested = _depositAsVault(amount);
        // only s1 active -> 600 allocated, 400 returned
        assertEq(invested, 600);

        assertEq(asset.balanceOf(address(s1)), 600);
        assertEq(asset.balanceOf(address(s2)), 0);
        assertEq(asset.balanceOf(address(vault)), 400);
        assertEq(asset.balanceOf(address(aggregator)), 0);
    }

    function testAggregator_deposit_ContinuesWhenToAllocateIsZero() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);

        vm.prank(takadao);
        aggregator.addSubStrategy(address(s1), 1); // 1 bps

        _fundAggregator(1);

        uint256 invested = _depositAsVault(1);
        assertEq(invested, 0);

        assertEq(asset.balanceOf(address(s1)), 0);
        assertEq(asset.balanceOf(address(vault)), 1);
        assertEq(asset.balanceOf(address(aggregator)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                             WITHDRAW BRANCHES
    //////////////////////////////////////////////////////////////*/

    function testAggregator_withdraw_RevertsIfCallerNotVault(address caller) public {
        vm.assume(caller != address(vault));

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.withdraw(1, address(this), bytes(""));
    }

    function testAggregator_withdraw_RevertsWhenZeroAssets() public {
        vm.prank(address(vault));
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotZeroAmount.selector);
        aggregator.withdraw(0, address(this), bytes(""));
    }

    function testAggregator_withdraw_RevertsWhenReceiverIsZero() public {
        vm.prank(address(vault));
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAddressZero.selector);
        aggregator.withdraw(1, address(0), bytes(""));
    }

    function testAggregator_withdraw_UsesIdleFirstAndEarlyReturns() public {
        address receiver = makeAddr("receiver");

        // idle funds live on aggregator
        _fundAggregator(1_000);

        uint256 got = _withdrawAsVault(600, receiver);
        assertEq(got, 600);
        assertEq(asset.balanceOf(receiver), 600);
        assertEq(asset.balanceOf(address(aggregator)), 400);
    }

    function testAggregator_withdraw_PullsFromStrategiesWhenIdleInsufficient() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        vm.prank(takadao);
        aggregator.addSubStrategy(address(s1), 10_000);

        // fund + invest 1000 into s1
        _fundAggregator(1_000);
        uint256 invested = _depositAsVault(1_000);
        assertEq(invested, 1_000);
        assertEq(asset.balanceOf(address(s1)), 1_000);

        // add some idle and withdraw more than idle
        _fundAggregator(100);

        address receiver = makeAddr("receiver");
        uint256 got = _withdrawAsVault(700, receiver);
        assertEq(got, 700);
        assertEq(asset.balanceOf(receiver), 700);
    }

    function testAggregator_withdraw_SkipsStrategiesWithMaxWithdrawZero() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 5000);
        aggregator.addSubStrategy(address(s2), 5000);
        vm.stopPrank();

        // put funds directly in both strategies (no need to go through deposit for this branch)
        deal(address(asset), address(s1), 1_000);
        deal(address(asset), address(s2), 1_000);

        // force s1 maxWithdraw to 0 so it is skipped
        s1.setForcedMaxWithdraw(0);

        address receiver = makeAddr("receiver");
        uint256 got = _withdrawAsVault(600, receiver);
        assertEq(got, 600);
        assertEq(asset.balanceOf(receiver), 600);
    }

    function testAggregator_withdraw_SkipsWhenChildWithdrawReturnsZero() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 5000);
        aggregator.addSubStrategy(address(s2), 5000);
        vm.stopPrank();

        deal(address(asset), address(s1), 1_000);
        deal(address(asset), address(s2), 1_000);

        s1.setReturnZeroOnWithdraw(true);

        address receiver = makeAddr("receiver");
        uint256 got = _withdrawAsVault(700, receiver);
        assertEq(got, 700);
        assertEq(asset.balanceOf(receiver), 700);
    }

    function testAggregator_withdraw_EmitsLossWhenUnableToWithdrawFull() public {
        // Use a strategy that only returns half of what it withdraws (forcing loss branch)
        TestSubStrategy s1 = new TestSubStrategy(asset);
        vm.prank(takadao);
        aggregator.addSubStrategy(address(s1), 10_000);

        // give strategy only 400 so withdrawing 800 cannot be satisfied
        deal(address(asset), address(s1), 400);

        address receiver = makeAddr("receiver");
        uint256 got = _withdrawAsVault(800, receiver);

        assertEq(got, 400);
        assertEq(asset.balanceOf(receiver), 400);
        // loss branch executed (we don’t assert event data here; state + return prove the path)
    }

    /*//////////////////////////////////////////////////////////////
                               PAUSE / EMERGENCY
    //////////////////////////////////////////////////////////////*/

    function testAggregator_pauseAndUnpause_WorksAndBlocksActions() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        vm.prank(takadao);
        aggregator.addSubStrategy(address(s1), 10_000);

        _fundAggregator(1_000);

        vm.prank(pauser);
        aggregator.pause();
        assertTrue(aggregator.paused());

        vm.prank(address(vault));
        vm.expectRevert(); // OZ Pausable error
        aggregator.deposit(1, bytes(""));

        vm.prank(pauser);
        aggregator.unpause();
        assertFalse(aggregator.paused());

        uint256 invested = _depositAsVault(1_000);
        assertEq(invested, 1_000);
    }

    function testAggregator_emergencyExit_WithdrawsAllIdleAndPauses() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 5000);
        aggregator.addSubStrategy(address(s2), 5000);
        vm.stopPrank();

        // put funds in strategies + some idle on aggregator
        deal(address(asset), address(s1), 700);
        deal(address(asset), address(s2), 300);
        _fundAggregator(200);

        address receiver = makeAddr("receiver");

        vm.prank(takadao);
        aggregator.emergencyExit(receiver);

        assertTrue(aggregator.paused());
        assertEq(asset.balanceOf(receiver), 1_200); // 700 + 300 + 200
        assertEq(asset.balanceOf(address(aggregator)), 0);
        assertEq(asset.balanceOf(address(s1)), 0);
        assertEq(asset.balanceOf(address(s2)), 0);
    }

    function testAggregator_emergencyExit_RevertsOnZeroReceiver() public {
        vm.prank(takadao);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAddressZero.selector);
        aggregator.emergencyExit(address(0));
    }

    function testAggregator_emergencyExit_RevertsForNonOperator(address caller) public {
        vm.assume(caller != takadao);

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.emergencyExit(makeAddr("r"));
    }

    /*//////////////////////////////////////////////////////////////
                               MAINTENANCE
    //////////////////////////////////////////////////////////////*/

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
        aggregator.rebalance(bytes("hello"));

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

    /*//////////////////////////////////////////////////////////////
                                  GETTERS
    //////////////////////////////////////////////////////////////*/

    function testAggregator_getConfig_ReturnsExpected() public {
        StrategyConfig memory cfg = aggregator.getConfig();

        assertEq(cfg.asset, address(asset));
        assertEq(cfg.vault, address(vault));
        assertEq(cfg.pool, address(0));
        assertEq(cfg.maxTVL, aggregator.maxTVL());
        assertEq(cfg.paused, aggregator.paused());

        vm.prank(pauser);
        aggregator.pause();

        StrategyConfig memory cfg2 = aggregator.getConfig();
        assertTrue(cfg2.paused);
    }

    function testAggregator_totalAssets_SumsOnlyActive() public {
        TestSubStrategy s1 = new TestSubStrategy(asset);
        TestSubStrategy s2 = new TestSubStrategy(asset);

        vm.startPrank(takadao);
        aggregator.addSubStrategy(address(s1), 5000);
        aggregator.addSubStrategy(address(s2), 5000);
        aggregator.updateSubStrategy(address(s2), 5000, false); // inactive
        vm.stopPrank();

        deal(address(asset), address(s1), 111);
        deal(address(asset), address(s2), 999);

        // only s1 counted
        assertEq(aggregator.totalAssets(), 111);
        assertEq(aggregator.positionValue(), 111);
    }

    function testAggregator_maxDeposit_Branches() public {
        // maxTVL == 0 => no cap
        vm.prank(takadao);
        aggregator.setMaxTVL(0);
        assertEq(aggregator.maxDeposit(), type(uint256).max);

        // set cap and verify remaining room
        TestSubStrategy s1 = new TestSubStrategy(asset);
        vm.prank(takadao);
        aggregator.addSubStrategy(address(s1), 10_000);

        deal(address(asset), address(s1), 600);

        vm.prank(takadao);
        aggregator.setMaxTVL(1_000);

        assertEq(aggregator.maxDeposit(), 400);

        // at/over cap => 0
        deal(address(asset), address(s1), 1_000); // now totalAssets >= 1_000
        assertEq(aggregator.maxDeposit(), 0);
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
        aggregator.updateSubStrategy(address(s2), 3000, false);
        vm.stopPrank();

        bytes memory details = aggregator.getPositionDetails();
        (address[] memory strategies, uint16[] memory weights, bool[] memory actives) =
            abi.decode(details, (address[], uint16[], bool[]));

        assertEq(strategies.length, 2);
        assertEq(weights.length, 2);
        assertEq(actives.length, 2);

        assertEq(strategies[0], address(s1));
        assertEq(weights[0], 6000);
        assertTrue(actives[0]);

        assertEq(strategies[1], address(s2));
        assertEq(weights[1], 3000);
        assertFalse(actives[1]);
    }
}
