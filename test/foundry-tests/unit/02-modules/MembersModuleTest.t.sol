// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {MembersModule} from "../../../../contracts/modules/MembersModule.sol";
import {DeployMembersModule} from "../../../../scripts/foundry-deploy/02-modules/DeployMembersModule.s.sol";
import {DeployTakaTokenAndTakasurePool} from "../../../../scripts/foundry-deploy/01-taka-token-takasure-pool/DeployTakaTokenAndTakasurePool.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {HelperConfig} from "../../../../scripts/foundry-deploy/HelperConfig.s.sol";

contract MembesModuleTest is StdCheats, Test {
    DeployMembersModule deployer;
    DeployTakaTokenAndTakasurePool deployerTakaTokenAndTakasurePool;
    MembersModule membersModule;
    HelperConfig config;

    address usdc;
    address takasurePool;

    address public admin = makeAddr("admin");

    event PoolCreated(uint256 indexed fundId);

    function setUp() public {
        config = new HelperConfig();
        (usdc, , takasurePool, ) = config.activeNetworkConfig();

        deployer = new DeployMembersModule();
        address proxy = deployer.run();

        membersModule = MembersModule(proxy);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/
    function testMembersModule_getWakalaFee() public view {
        uint256 wakalaFee = membersModule.getWakalaFee();
        uint256 expectedWakalaFee = 20;

        assertEq(wakalaFee, expectedWakalaFee);
    }

    function testMembersModule_getMinimumThreshold() public view {
        uint256 minimumThreshold = membersModule.getMinimumThreshold();
        uint256 expectedMinimumThreshold = 25e6;

        assertEq(minimumThreshold, expectedMinimumThreshold);
    }

    /*//////////////////////////////////////////////////////////////
                              CREATE POOL
    //////////////////////////////////////////////////////////////*/

    function testMembersModule_createPool() public {
        uint256 fundIdCounterBefore = membersModule.fundIdCounter();

        vm.prank(admin);

        vm.expectEmit(true, false, false, false, address(membersModule));
        emit PoolCreated(fundIdCounterBefore + 1);

        membersModule.createPool();

        uint256 fundIdCounterAfter = membersModule.fundIdCounter();

        assertEq(fundIdCounterAfter, fundIdCounterBefore + 1);
    }

    /*//////////////////////////////////////////////////////////////
                               JOIN POOL
    //////////////////////////////////////////////////////////////*/

    modifier createPool() {
        vm.prank(admin);
        membersModule.createPool();
        _;
    }
}
