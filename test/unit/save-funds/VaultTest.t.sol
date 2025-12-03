// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeploySFVault} from "test/utils/05-DeploySFVault.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";

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

    function testSanity() public {
        assert(2 + 2 == 4);
    }
}
