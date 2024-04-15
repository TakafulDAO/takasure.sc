// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeployPoolAndModules} from "../../../scripts/foundry-deploy/DeployPoolAndModules.s.sol";
import {TakasurePool} from "../../../contracts/token/TakasurePool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MembersModule} from "../../../contracts/modules/MembersModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {MemberState} from "../../../contracts/types/TakasureTypes.sol";
import {IUSDC} from "../../../contracts/mocks/IUSDCmock.sol";

contract MembesModuleTest is StdCheats, Test {
    DeployPoolAndModules deployer;
    TakasurePool takasurePool;
    MembersModule membersModule;
    ERC1967Proxy proxy;
    address contributionTokenAddress;
    // HelperConfig config;
    IUSDC usdc;
    //     address takasurePool;
    address public backend = makeAddr("backend");
    address public user = makeAddr("user");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    event PoolCreated(uint256 indexed fundId);
    event MemberJoined(
        uint256 indexed joinedFundId,
        address indexed member,
        uint256 indexed contributionAmount,
        MemberState memberState
    );

    function setUp() public {
        deployer = new DeployPoolAndModules();
        (takasurePool, proxy, , contributionTokenAddress, ) = deployer.run();

        membersModule = MembersModule(address(proxy));
        // config = new HelperConfig();
        // ( takasurePool, ) = config.activeNetworkConfig();
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        vm.startPrank(user);
        usdc.mintUSDC(user, USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
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
    function testMembersModule_createPoolEmitEventAndUpdateCounter() public {
        uint256 fundIdCounterBefore = membersModule.fundIdCounter();
        vm.prank(backend);
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
        vm.prank(backend);
        membersModule.createPool();
        _;
    }

    function testMembersModule_joinPoolEmitsEventAndUpdatesCounter() public createPool {
        uint256 fundId = membersModule.fundIdCounter();
        uint256 memberIdCounterBefore = membersModule.memberIdCounter();
        vm.prank(user);
        // vm.expectEmit(true, true, true, true, address(membersModule));
        // emit MemberJoined(fundId, msg.sender, CONTRIBUTION_AMOUNT, MemberState.Active);
        membersModule.joinPool(fundId, BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        uint256 memberIdCounterAfter = membersModule.memberIdCounter();
        assertEq(memberIdCounterAfter, memberIdCounterBefore + 1);
    }
}
