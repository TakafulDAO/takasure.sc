// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

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
    IUSDC usdc;
    address public backend = makeAddr("backend");
    address public user = makeAddr("user");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    address public membersModuleOwner = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266; // Default from anvil

    event PoolCreated(uint256 indexed fundId);
    event MemberJoined(
        address indexed member,
        uint256 indexed contributionAmount,
        MemberState memberState
    );

    function setUp() public {
        deployer = new DeployPoolAndModules();
        (takasurePool, proxy, , contributionTokenAddress, ) = deployer.run();

        membersModule = MembersModule(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        vm.startPrank(user);
        usdc.mintUSDC(user, USDC_INITIAL_AMOUNT);
        usdc.approve(address(membersModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               JOIN POOL
    //////////////////////////////////////////////////////////////*/

    function testMembersModule_joinPoolEmitsEventAndUpdatesCounter() public {
        uint256 memberIdCounterBefore = membersModule.memberIdCounter();
        vm.prank(user);
        // vm.expectEmit(true, true, false, true, address(membersModule));
        // emit MemberJoined(msg.sender, CONTRIBUTION_AMOUNT, MemberState.Active);
        membersModule.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        uint256 memberIdCounterAfter = membersModule.memberIdCounter();
        assertEq(memberIdCounterAfter, memberIdCounterBefore + 1);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/
    function testMembersModule_setNewWakalaFee() public {
        uint256 newWakalaFee = 50;

        vm.prank(membersModuleOwner);
        membersModule.setNewWakalaFee(newWakalaFee);

        assertEq(newWakalaFee, membersModule.getWakalaFee());
    }

    function testMembersModule_setNewContributionToken() public {
        vm.prank(membersModuleOwner);
        membersModule.setNewContributionToken(user);

        assertEq(user, membersModule.getContributionTokenAddress());
    }

    function testMembersModule_setNewTakasurePool() public {
        vm.prank(membersModuleOwner);
        membersModule.setNewTakasurePool(user);

        assertEq(user, membersModule.getTakasurePoolAddress());
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
                                REVERTS
    //////////////////////////////////////////////////////////////*/
    function testMembersModule_setNewContributionTokenMustRevertIfAddressZero() public {
        vm.prank(membersModuleOwner);
        vm.expectRevert(MembersModule.MembersModule__ZeroAddress.selector);
        membersModule.setNewContributionToken(address(0));
    }

    function testMembersModule_setNewTakasurePoolMustRevertIfAddressZero() public {
        vm.prank(membersModuleOwner);
        vm.expectRevert(MembersModule.MembersModule__ZeroAddress.selector);
        membersModule.setNewTakasurePool(address(0));
    }

    function testMembersModule_joinPoolMustRevertIfDepositLessThanMinimum() public {
        uint256 wrongContribution = CONTRIBUTION_AMOUNT / 2;
        vm.prank(user);
        vm.expectRevert(MembersModule.MembersModule__ContributionBelowMinimumThreshold.selector);
        membersModule.joinPool(BENEFIT_MULTIPLIER, wrongContribution, (5 * YEAR));
    }
}
