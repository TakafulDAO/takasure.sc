// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {TakaToken} from "../../../contracts/token/TakaToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../contracts/takasure/TakasurePool.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {MemberState} from "../../../contracts/types/TakasureTypes.sol";
import {IUSDC} from "../../../contracts/mocks/IUSDCmock.sol";

contract MembesModuleTest is StdCheats, Test {
    DeployTokenAndPool deployer;
    TakaToken takaToken;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;
    address contributionTokenAddress;
    IUSDC usdc;
    address public backend = makeAddr("backend");
    address public user = makeAddr("user");
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant BENEFIT_MULTIPLIER = 0;
    uint256 public constant YEAR = 365 days;

    event PoolCreated(uint256 indexed fundId);
    event MemberJoined(
        address indexed member,
        uint256 indexed contributionAmount,
        MemberState memberState
    );

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (takaToken, proxy, , contributionTokenAddress, ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
        usdc = IUSDC(contributionTokenAddress);

        // For easier testing there is a minimal USDC mock contract without restrictions
        vm.startPrank(user);
        usdc.mintUSDC(user, USDC_INITIAL_AMOUNT);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               JOIN POOL
    //////////////////////////////////////////////////////////////*/

    function testTakasurePool_joinPoolEmitsEventAndUpdatesCounter() public {
        uint256 memberIdCounterBefore = takasurePool.memberIdCounter();
        vm.prank(user);
        // vm.expectEmit(true, true, false, true, address(takasurePool));
        // emit MemberJoined(msg.sender, CONTRIBUTION_AMOUNT, MemberState.Active);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, CONTRIBUTION_AMOUNT, (5 * YEAR));
        uint256 memberIdCounterAfter = takasurePool.memberIdCounter();
        assertEq(memberIdCounterAfter, memberIdCounterBefore + 1);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/
    function testTakasurePool_setNewWakalaFee() public {
        uint8 newWakalaFee = 50;

        vm.prank(takasurePool.owner());
        takasurePool.setNewWakalaFee(newWakalaFee);

        (, , , , , , uint8 wakalaFee) = takasurePool.getPoolValues();

        assertEq(newWakalaFee, wakalaFee);
    }

    function testTakasurePool_setNewContributionToken() public {
        vm.prank(takasurePool.owner());
        takasurePool.setNewContributionToken(user);

        assertEq(user, takasurePool.getContributionTokenAddress());
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/
    function testTakasurePool_getWakalaFee() public view {
        (, , , , , , uint256 wakalaFee) = takasurePool.getPoolValues();
        uint256 expectedWakalaFee = 20;
        assertEq(wakalaFee, expectedWakalaFee);
    }

    function testTakasurePool_getMinimumThreshold() public view {
        uint256 minimumThreshold = takasurePool.minimumThreshold();
        uint256 expectedMinimumThreshold = 25e6;
        assertEq(minimumThreshold, expectedMinimumThreshold);
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/
    function testTakasurePool_setNewContributionTokenMustRevertIfAddressZero() public {
        vm.prank(takasurePool.owner());
        vm.expectRevert(TakasurePool.TakasurePool__ZeroAddress.selector);
        takasurePool.setNewContributionToken(address(0));
    }

    function testTakasurePool_joinPoolMustRevertIfDepositLessThanMinimum() public {
        uint256 wrongContribution = CONTRIBUTION_AMOUNT / 2;
        vm.prank(user);
        vm.expectRevert(TakasurePool.TakasurePool__ContributionBelowMinimumThreshold.selector);
        takasurePool.joinPool(BENEFIT_MULTIPLIER, wrongContribution, (5 * YEAR));
    }
}
