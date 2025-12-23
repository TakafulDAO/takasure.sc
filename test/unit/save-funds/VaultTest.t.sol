// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFVault} from "test/utils/05-DeploySFVault.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";

import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";

contract VaultTest is Test {
    DeployManagers managersDeployer;
    DeploySFVault vaultDeployer;
    AddAddressesAndRoles internal addressesAndRoles;

    SFVault vault;
    AddressManager addrMgr;
    ModuleManager modMgr;
    address takadao;
    address internal backend;

    function setUp() public {
        managersDeployer = new DeployManagers();
        vaultDeployer = new DeploySFVault();
        addressesAndRoles = new AddAddressesAndRoles();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();

        (address operatorAddr,,, address backendAddr,,,) = addressesAndRoles.run(_addrMgr, config, address(_modMgr));

        addrMgr = _addrMgr;
        modMgr = _modMgr;
        takadao = operatorAddr;
        backend = backendAddr;

        (vault) = vaultDeployer.run(addrMgr);

        vm.prank(addrMgr.owner());
        addrMgr.addProtocolAddress("ADMIN__SF_FEE_RECEIVER", makeAddr("feeRecipient"), ProtocolAddressType.Admin);
    }

    function testSetAndGetCaps() public {
        vm.prank(takadao);
        vault.setTVLCap(1_000_000);
        assertEq(vault.TVLCap(), 1_000_000);
    }

    function testMaxDepositRespectsCaps() public {
        vm.prank(backend);
        vault.registerMember(address(this));
        vm.prank(takadao);
        vault.setTVLCap(1000);
        uint256 maxDeposit = vault.maxDeposit(address(this));
        assertEq(maxDeposit, 1000);
    }

    function testSetFeeConfigRevertsOnInvalidBps() public {
        vm.expectRevert();
        vault.setFeeConfig(10_001, 0, 0);
    }

    function testSetStrategyUpdates() public {
        address newStrat = address(0x1234);
        vm.prank(takadao);
        vault.setStrategy(ISFStrategy(newStrat));
        assertEq(address(vault.strategy()), newStrat);
    }

    function testNonTransferableSharesReverts() public {
        IERC20 asset = IERC20(vault.asset());
        deal(address(asset), address(this), 1_000_000);
        asset.approve(address(vault), 1_000_000);
        vm.prank(backend);
        vault.registerMember(address(this));
        vault.deposit(1_000_000, address(this));

        uint256 bal = vault.balanceOf(address(this));
        assertGt(bal, 0);

        vm.expectRevert();
        vault.transfer(address(0xBEEF), bal);
    }
}
