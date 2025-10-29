// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {DeployReserve} from "test/utils/02-DeployReserve.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Reserve} from "contracts/types/TakasureTypes.sol";

contract Getters_TakasureCoreTest is StdCheats, Test {
    DeployManagers managersDeployer;
    DeployReserve deployer;
    TakasureReserve takasureReserve;

    function setUp() public {
        managersDeployer = new DeployManagers();
        deployer = new DeployReserve();
        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addressManager,

        ) = managersDeployer.run();
        takasureReserve = deployer.run(config, addressManager);
    }

    function testTakasureCore_getServiceFee() public view {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint8 expectedServiceFee = 27;
        assertEq(reserve.serviceFee, expectedServiceFee);
    }

    function testTakasureCore_getMinimumThreshold() public view {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint256 expectedMinimumThreshold = 25e6;
        assertEq(reserve.minimumThreshold, expectedMinimumThreshold);
    }
}
