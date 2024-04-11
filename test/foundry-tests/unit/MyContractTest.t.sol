// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeployMyContract} from "../../../scripts/foundry-deploy/DeployMyContract.s.sol";
import {HelperConfig} from "../../../scripts/foundry-deploy/HelperConfig.s.sol";
import {MyContract} from "../../../contracts/MyContract.sol";

contract MyContractTest is Test {
    DeployMyContract deployer;
    MyContract myContract;
    HelperConfig config;

    function setUp() public {
        deployer = new DeployMyContract();
        (myContract, config) = deployer.run();
    }

    function testSanityCheck() public {
        uint256 expected = 10;
        myContract.setNumber(10);
        uint256 actual = myContract.myNumber();
        assertEq(expected, actual);
    }
}
