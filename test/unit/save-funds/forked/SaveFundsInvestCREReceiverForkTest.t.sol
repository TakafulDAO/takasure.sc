// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {SFVault} from "contracts/saveFunds/protocol/SFVault.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/protocol/SFStrategyAggregator.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/protocol/SFUniswapV3Strategy.sol";
import {
    SaveFundsInvestAutomationRunner
} from "contracts/helpers/chainlink/automation/SaveFundsInvestAutomationRunner.sol";
import {SaveFundsInvestCREReceiver} from "contracts/helpers/chainlink/automation/SaveFundsInvestCREReceiver.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ProtocolAddress, ProtocolAddressType} from "contracts/types/Managers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract SaveFundsInvestCREReceiverForkTest is Test {
    uint256 internal constant FORK_BLOCK = 430826360;
    bytes32 internal constant ON_INVEST_SIG = keccak256("OnInvestIntoStrategy(uint256,uint256,bytes32)");
    bytes32 internal constant ON_UPKEEP_ATTEMPT_SIG = keccak256("OnUpkeepAttempt(uint256,uint256,uint16,bytes32)");
    bytes32 internal constant ON_INVEST_SUCCEEDED_SIG = keccak256("OnInvestSucceeded(uint256,uint256,uint256,uint16)");
    bytes32 internal constant ON_INVEST_FAILED_SIG = keccak256("OnInvestFailed(uint256,bytes)");

    string internal constant CRE_FORWARDER_NAME = "EXTERNAL__CL_CRE_FORWARDER";
    string internal constant SAVE_FUNDS_RUNNER_NAME = "HELPER__SF_INVEST_RUNNER";

    AddressGetterCRE internal addrGetter;
    AddressManager internal addrMgr;
    SFVault internal vault;
    SFStrategyAggregator internal aggregator;
    SFUniswapV3Strategy internal uniV3;
    IERC20 internal asset;

    SaveFundsInvestAutomationRunner internal runner;
    SaveFundsInvestCREReceiver internal receiver;

    address internal operator;
    address internal backendAdmin;
    address internal pauseGuardian;
    address internal forwarder;

    function setUp() public {
        uint256 forkId = vm.createFork(vm.envString("ARBITRUM_MAINNET_RPC_URL"), FORK_BLOCK);
        vm.selectFork(forkId);

        addrGetter = new AddressGetterCRE();

        addrMgr = AddressManager(_getAddr("AddressManager"));
        vault = SFVault(_getAddr("SFVault"));
        aggregator = SFStrategyAggregator(_getAddr("SFStrategyAggregator"));
        uniV3 = SFUniswapV3Strategy(_getAddr("SFUniswapV3Strategy"));
        asset = IERC20(vault.asset());

        operator = addrMgr.currentRoleHolders(Roles.OPERATOR);
        backendAdmin = addrMgr.currentRoleHolders(Roles.BACKEND_ADMIN);
        pauseGuardian = addrMgr.currentRoleHolders(Roles.PAUSE_GUARDIAN);
        forwarder = makeAddr("forwarder");

        require(operator != address(0) && addrMgr.hasRole(Roles.OPERATOR, operator), "operator missing");

        _ensureBackendAdmin();
        _ensureUnpaused();

        vm.prank(operator);
        vault.setTVLCap(0);

        address runnerImplementation = address(new SaveFundsInvestAutomationRunner());
        address runnerProxy = UnsafeUpgrades.deployUUPSProxy(
            runnerImplementation,
            abi.encodeCall(
                SaveFundsInvestAutomationRunner.initialize,
                (address(vault), address(aggregator), address(uniV3), address(addrMgr), 24 hours, 1, address(this))
            )
        );
        runner = SaveFundsInvestAutomationRunner(runnerProxy);

        if (runner.strictUniOnlyAllocation()) runner.toggleStrictUniOnlyAllocation();
        if (runner.skipIfPaused()) runner.toggleSkipIfPaused();

        _grantKeeperRoleToRunner();
        _setOrAddProtocolAddress(SAVE_FUNDS_RUNNER_NAME, address(runner), ProtocolAddressType.Helper);
        _setOrAddProtocolAddress(CRE_FORWARDER_NAME, forwarder, ProtocolAddressType.External);

        receiver = new SaveFundsInvestCREReceiver(addrMgr);
    }

    function testReceiverFork_onReport_CallsRunnerAndAttemptsInvestment() public {
        bytes memory metadata = "";
        bytes memory report = hex"cafe";
        bytes32 executionKey = keccak256(abi.encode(metadata, report));

        _registerAndDeposit(makeAddr("memberReceiver"), 2_000e6);
        vm.warp(block.timestamp + runner.interval() + 1);

        (bool upkeepNeeded,) = runner.checkUpkeep("");
        assertTrue(upkeepNeeded, "upkeep should be needed before receiver call");

        vm.recordLogs();
        vm.prank(forwarder);
        receiver.onReport(metadata, report);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bool foundAttempt;
        bool foundVaultInvestEvent;
        bool foundRunnerSuccess;
        bool foundRunnerFailed;

        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(runner) && logs[i].topics.length > 0) {
                if (logs[i].topics[0] == ON_UPKEEP_ATTEMPT_SIG) {
                    foundAttempt = true;
                } else if (logs[i].topics[0] == ON_INVEST_SUCCEEDED_SIG) {
                    foundRunnerSuccess = true;
                } else if (logs[i].topics[0] == ON_INVEST_FAILED_SIG) {
                    foundRunnerFailed = true;
                }
            }

            if (logs[i].emitter == address(vault) && logs[i].topics.length > 0 && logs[i].topics[0] == ON_INVEST_SIG) {
                foundVaultInvestEvent = true;
            }
        }

        assertTrue(receiver.consumedReports(executionKey), "report not marked consumed");
        assertTrue(foundAttempt, "runner attempt event not emitted");
        assertTrue(foundRunnerSuccess || foundRunnerFailed, "runner terminal event missing");
        assertTrue(!(foundRunnerSuccess && foundRunnerFailed), "runner emitted both success and failed");
        assertEq(runner.lastRun(), block.timestamp, "lastRun not updated");

        if (foundRunnerSuccess) {
            assertTrue(foundVaultInvestEvent, "vault invest event missing on runner success");
        } else {
            assertFalse(foundVaultInvestEvent, "vault invest event should not exist on runner failure");
        }
    }

    function _getAddr(string memory contractName) internal view returns (address) {
        return addrGetter.getAddress(block.chainid, contractName);
    }

    function _ensureBackendAdmin() internal {
        if (backendAdmin != address(0) && addrMgr.hasRole(Roles.BACKEND_ADMIN, backendAdmin)) return;

        address owner = addrMgr.owner();
        backendAdmin = makeAddr("backendAdminReceiver");

        vm.prank(owner);
        addrMgr.proposeRoleHolder(Roles.BACKEND_ADMIN, backendAdmin);

        vm.prank(backendAdmin);
        addrMgr.acceptProposedRole(Roles.BACKEND_ADMIN);
    }

    function _ensureUnpaused() internal {
        if (pauseGuardian == address(0) || !addrMgr.hasRole(Roles.PAUSE_GUARDIAN, pauseGuardian)) return;

        if (vault.paused()) {
            vm.prank(pauseGuardian);
            vault.unpause();
        }
        if (aggregator.paused()) {
            vm.prank(pauseGuardian);
            aggregator.unpause();
        }
        if (uniV3.paused()) {
            vm.prank(pauseGuardian);
            uniV3.unpause();
        }
    }

    function _grantKeeperRoleToRunner() internal {
        address owner = addrMgr.owner();
        vm.prank(owner);
        addrMgr.proposeRoleHolder(Roles.KEEPER, address(runner));
        runner.acceptKeeperRole();
    }

    function _registerAndDeposit(address user, uint256 amount) internal {
        vm.prank(backendAdmin);
        vault.registerMember(user);

        uint256 maxDep = vault.maxDeposit(user);
        uint256 toDeposit = amount > maxDep ? maxDep : amount;
        require(toDeposit > 0, "maxDeposit is zero");

        deal(address(asset), user, toDeposit);
        vm.startPrank(user);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(toDeposit, user);
        vm.stopPrank();
    }

    function _setOrAddProtocolAddress(string memory name, address addr, ProtocolAddressType addressType) internal {
        address owner = addrMgr.owner();

        try addrMgr.getProtocolAddressByName(name) returns (ProtocolAddress memory protocolAddress) {
            if (protocolAddress.addr == addr) return;

            vm.prank(owner);
            addrMgr.updateProtocolAddress(name, addr);
        } catch {
            vm.prank(owner);
            addrMgr.addProtocolAddress(name, addr, addressType);
        }
    }
}

contract AddressGetterCRE is GetContractAddress {
    function getAddress(uint256 chainId, string memory contractName) external view returns (address) {
        return _getContractAddress(chainId, contractName);
    }
}
