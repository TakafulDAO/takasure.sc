// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFVault} from "test/utils/05-DeploySFVault.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISFStrategy} from "contracts/interfaces/saveFunds/ISFStrategy.sol";

contract VaultTest is Test {
    DeployManagers managersDeployer;
    DeploySFVault vaultDeployer;

    SFVault vault;
    AddressManager addrMgr;
    ModuleManager modMgr;

    function setUp() public {
        managersDeployer = new DeployManagers();
        vaultDeployer = new DeploySFVault();

        (HelperConfig.NetworkConfig memory config, AddressManager _addrMgr, ModuleManager _modMgr) =
            managersDeployer.run();

        addrMgr = _addrMgr;
        modMgr = _modMgr;

        (vault) = vaultDeployer.run(addrMgr);
    }

    function testSetAndGetCaps() public {
        vault.setTvlCap(1_000_000);
        vault.setPerUserCap(500_000);
        assertEq(vault.tvlCap(), 1_000_000);
        assertEq(vault.perUserCap(), 500_000);
    }

    function testMaxDepositRespectsCaps() public {
        vault.setTvlCap(1000);
        vault.setPerUserCap(500);
        uint256 maxDeposit = vault.maxDeposit(address(this));
        assertEq(maxDeposit, 500);
    }

    function testSetFeeConfigRevertsOnInvalidBps() public {
        vm.expectRevert();
        vault.setFeeConfig(10_001, 0, 0);
    }

    function testSetStrategyUpdates() public {
        address newStrat = address(0x1234);
        vault.setStrategy(ISFStrategy(newStrat));
        assertEq(address(vault.strategy()), newStrat);
    }

    function testNonTransferableSharesReverts() public {
        IERC20 asset = IERC20(vault.asset());
        deal(address(asset), address(this), 1_000_000);
        asset.approve(address(vault), 1_000_000);
        vault.deposit(1_000_000, address(this));

        uint256 bal = vault.balanceOf(address(this));
        assertGt(bal, 0);

        vm.expectRevert();
        vault.transfer(address(0xBEEF), bal);
    }
}
