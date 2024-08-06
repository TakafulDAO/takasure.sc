// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";

contract TokenTest is Test {
    TestDeployTakasure deployer;
    TSToken daoToken;
    TakasurePool takasurePool;
    address proxy;

    address public admin = makeAddr("admin");
    address public user = makeAddr("user");

    uint256 public constant MINT_AMOUNT = 1 ether;

    event OnTokenMinted(address indexed to, uint256 indexed amount);
    event OnTokenBurned(address indexed from, uint256 indexed amount);

    function setUp() public {
        deployer = new TestDeployTakasure();
        (daoToken, proxy, , ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                             MINT FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testToken_mintUpdateBalanceAndEmitEvent() public {
        // Get users balance from the mapping and the balanceOf function to check if they match up
        uint256 userBalanceBefore = daoToken.balanceOf(user);

        vm.prank(address(takasurePool));

        // Event should be emitted
        vm.expectEmit(true, true, false, false, address(daoToken));
        emit OnTokenMinted(user, MINT_AMOUNT);
        daoToken.mint(user, MINT_AMOUNT);

        // And the balance should be updated
        uint256 userBalanceAfter = daoToken.balanceOf(user);

        assert(userBalanceAfter > userBalanceBefore);

        assertEq(userBalanceAfter, MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                             BURN FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testToken_burnUpdateBalanceAndEmitEvent() public {
        uint256 burnAmount = MINT_AMOUNT / 2;

        // Mint some tokens to the user
        vm.startPrank(address(takasurePool));
        daoToken.mint(address(takasurePool), MINT_AMOUNT);
        uint256 balanceBefore = daoToken.balanceOf(address(takasurePool));

        // Expect to emit the event
        vm.expectEmit(true, true, false, false, address(daoToken));
        emit OnTokenBurned(address(takasurePool), burnAmount);
        daoToken.burn(burnAmount);
        uint256 balanceAfter = daoToken.balanceOf(address(takasurePool));
        vm.stopPrank();
        assert(balanceBefore > balanceAfter);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/
    function testToken_TakasurePoolIsMinterAndBurner() public view {
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");

        bool isMinter = daoToken.hasRole(MINTER_ROLE, address(takasurePool));
        bool isBurner = daoToken.hasRole(BURNER_ROLE, address(takasurePool));

        assert(isMinter);
        assert(isBurner);
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testToken_mustRevertIfTryToMintToAddressZero() public {
        vm.prank(address(takasurePool));
        vm.expectRevert(TSToken.Token__NotZeroAddress.selector);
        daoToken.mint(address(0), MINT_AMOUNT);
    }

    function testToken_mustRevertIfTryToMintZero() public {
        vm.prank(address(takasurePool));
        vm.expectRevert(TSToken.Token__MustBeMoreThanZero.selector);
        daoToken.mint(user, 0);
    }

    function testToken_mustRevertIfTryToBurnZero() public {
        vm.prank(address(takasurePool));
        vm.expectRevert(TSToken.Token__MustBeMoreThanZero.selector);
        daoToken.burn(0);
    }

    function testToken_mustRevertIfTryToBurnMoreThanBalance() public {
        uint256 userBalance = daoToken.balanceOf(user);
        vm.prank(address(takasurePool));
        vm.expectRevert(
            abi.encodeWithSelector(
                TSToken.Token__BurnAmountExceedsBalance.selector,
                userBalance,
                MINT_AMOUNT
            )
        );
        daoToken.burn(MINT_AMOUNT);
    }
}
