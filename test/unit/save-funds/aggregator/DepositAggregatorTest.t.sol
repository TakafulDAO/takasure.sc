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
import {TestSubStrategy, RecorderSubStrategy, PartialPullSubStrategy} from "test/mocks/MockSFStrategy.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ProtocolAddressType} from "contracts/types/Managers.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {SubStrategy} from "contracts/types/Strategies.sol";

contract DepositAggregatorTest is Test {
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

    function testAggregator_deposit_RevertsIfCallerNotVault(address caller) public {
        vm.assume(caller != address(vault));

        _fundAggregator(1);

        vm.prank(caller);
        vm.expectRevert(SFStrategyAggregator.SFStrategyAggregator__NotAuthorizedCaller.selector);
        aggregator.deposit(1, bytes(""));
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
                             Helpers
    //////////////////////////////////////////////////////////////*/

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

