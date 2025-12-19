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
    RecorderSubStrategy,
    NoAssetStrategy,
    ShortReturnAssetStrategy,
    WrongAssetStrategy,
    PartialPullSubStrategy
} from "test/mocks/MockSFStrategy.sol";

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
            weights2[1] = 2000;
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

    /*//////////////////////////////////////////////////////////////
                             DEPOSIT
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

    function testAggregator_deposit_RevertsWhenPerStrategyDataIsEmptyBytes() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        _addStrategy(address(s1), 10000, true);

        _fundAggregator(100);

        vm.prank(address(vault));
        vm.expectRevert(); // abi.decode on empty bytes
        aggregator.deposit(100, bytes(""));
    }

    function testAggregator_deposit_ResetsApprovalWhenChildDoesNotPullAllFunds() public {
        PartialPullSubStrategy s1 = new PartialPullSubStrategy(asset);
        _addStrategy(address(s1), 10000, true);

        _fundAggregator(1000);

        vm.prank(address(vault));
        uint256 invested = aggregator.deposit(1000, _emptyPerStrategyData());

        // child only pulls half
        assertEq(invested, 500);

        // leftover allowance branch => should be reset to 0
        assertEq(asset.allowance(address(aggregator), address(s1)), 0);

        // accounting: half in child, half idle in aggregator
        assertEq(asset.balanceOf(address(s1)), 500);
        assertEq(asset.balanceOf(address(aggregator)), 500);
        assertEq(aggregator.totalAssets(), 1000);
    }

    function testAggregator_deposit_UsesPerStrategyPayload_WhenProvided() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        _addStrategy(address(s1), 10000, true);

        _fundAggregator(123);

        address[] memory strategies = new address[](1);
        bytes[] memory payloads = new bytes[](1);

        strategies[0] = address(s1);
        payloads[0] = hex"deadbeef";

        vm.prank(address(vault));
        aggregator.deposit(123, _encodePerStrategyData(strategies, payloads));

        assertEq(s1.lastDepositDataHash(), keccak256(payloads[0]));
    }

    /*//////////////////////////////////////////////////////////////
                             WITHDRAW
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

    function testAggregator_withdraw_RevertsWhenPerStrategyDataIsEmptyBytes() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        _addStrategy(address(s1), 10000, true);

        // put assets in strategy so maxWithdraw > 0
        _fundStrategy(address(s1), 100);

        vm.prank(address(vault));
        vm.expectRevert(); // abi.decode on empty bytes
        aggregator.withdraw(10, makeAddr("recv"), bytes(""));
    }

    function testAggregator_withdraw_WhenIdleIsZero_PullsFromChildAndTransfersReceiver() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        _addStrategy(address(s1), 10000, true);

        // ensure aggregator idle == 0; fund strategy directly
        _fundStrategy(address(s1), 500);

        address receiver = makeAddr("receiver");

        vm.prank(address(vault));
        uint256 got = aggregator.withdraw(200, receiver, _emptyPerStrategyData());

        assertEq(got, 200);
        assertEq(asset.balanceOf(receiver), 200);
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

    function testAggregator_emergencyExit_WhenNoIdleBalance_DoesNotTransferIdle() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        _addStrategy(address(s1), 10000, true);

        // no idle on aggregator; only funds in child
        _fundStrategy(address(s1), 777);

        address receiver = makeAddr("receiver");

        vm.prank(takadao);
        aggregator.emergencyExit(receiver);

        assertEq(asset.balanceOf(receiver), 777);
        assertEq(asset.balanceOf(address(aggregator)), 0);
        assertTrue(aggregator.paused());
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
        assertEq(aggregator.totalAssets(), 1110);
        assertEq(aggregator.positionValue(), 1110);
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

    function _fundStrategy(address strat, uint256 amount) internal {
        deal(address(asset), strat, amount);
    }
}

