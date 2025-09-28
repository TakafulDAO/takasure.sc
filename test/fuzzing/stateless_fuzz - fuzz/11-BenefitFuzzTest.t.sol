// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {DeployReserve} from "test/utils/02-DeployReserve.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {BenefitModule} from "contracts/modules/BenefitModule.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ModuleErrors} from "contracts/helpers/libraries/errors/ModuleErrors.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {ModuleState} from "contracts/types/TakasureTypes.sol";

contract BenefitFuzzTest is StdCheats, Test {
    DeployManagers managersDeployer;
    DeployModules moduleDeployer;
    DeployReserve reserveDeployer;
    AddAddressesAndRoles addressesAndRoles;

    BenefitModule lifeModule;

    ModuleManager moduleManager;
    TakasureReserve takasureReserve;
    IUSDC usdc;

    address takadao;

    function setUp() public {
        managersDeployer = new DeployManagers();
        moduleDeployer = new DeployModules();
        reserveDeployer = new DeployReserve();
        addressesAndRoles = new AddAddressesAndRoles();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addressManager,
            ModuleManager moduleMgr
        ) = managersDeployer.run();

        (address operator, , , , , , ) = addressesAndRoles.run(
            addressManager,
            config,
            address(moduleMgr)
        );

        (lifeModule, , , , , , , ) = moduleDeployer.run(addressManager);

        takasureReserve = reserveDeployer.run(config, addressManager);

        takadao = operator;
        moduleManager = moduleMgr;
    }
}
