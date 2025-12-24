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

contract EmergencyAggregatorTest is Test {
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
}

