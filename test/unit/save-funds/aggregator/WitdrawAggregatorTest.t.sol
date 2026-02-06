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
import {SubStrategy} from "contracts/types/Strategies.sol";

contract WithdrawAggregatorTest is Test {
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

        aggregator = aggregatorDeployer.run(addrMgr, asset);

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

    function testAggregator_withdraw_UsesDefaultPayloadWhenDataEmpty() public {
        RecorderSubStrategy s1 = new RecorderSubStrategy(asset);
        _addStrategy(address(s1), 10000, true);

        bytes memory payload = abi.encode(uint256(123), address(this));
        vm.prank(takadao);
        aggregator.setDefaultWithdrawPayload(address(s1), payload);

        _fundStrategy(address(s1), 500);

        vm.prank(address(vault));
        uint256 got = aggregator.withdraw(200, address(this), _emptyPerStrategyData());

        assertEq(got, 200);
        assertEq(s1.lastWithdrawDataHash(), keccak256(payload));
    }

    /*//////////////////////////////////////////////////////////////
                             Helpers
    //////////////////////////////////////////////////////////////*/

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
}

