// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {TLDToken} from "../../../../contracts/token/TLDToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../../contracts/takasure/TakasurePool.sol";

contract TokenTest is Test {
    DeployTokenAndPool deployer;
    TLDToken tldToken;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;

    address public admin = makeAddr("admin");
    address public user = makeAddr("user");

    uint256 public constant MINT_AMOUNT = 1 ether;

    event TLDTokenMinted(address indexed to, uint256 indexed amount);
    event TLDTokenBurned(address indexed from, uint256 indexed amount);

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (tldToken, proxy, , , ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                             MINT FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testToken_mintUpdateBalanceAndEmitEvent() public {
        // Get users balance from the mapping and the balanceOf function to check if they match up
        uint256 userBalanceBefore = tldToken.balanceOf(user);

        vm.prank(address(takasurePool));

        // Event should be emitted
        vm.expectEmit(true, true, false, false, address(tldToken));
        emit TLDTokenMinted(user, MINT_AMOUNT);
        tldToken.mint(user, MINT_AMOUNT);

        // And the balance should be updated
        uint256 userBalanceAfter = tldToken.balanceOf(user);

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
        tldToken.mint(address(takasurePool), MINT_AMOUNT);
        uint256 balanceBefore = tldToken.balanceOf(address(takasurePool));

        // Expect to emit the event
        vm.expectEmit(true, true, false, false, address(tldToken));
        emit TLDTokenBurned(address(takasurePool), burnAmount);
        tldToken.burn(burnAmount);
        uint256 balanceAfter = tldToken.balanceOf(address(takasurePool));
        vm.stopPrank();
        assert(balanceBefore > balanceAfter);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/
    function testToken_TakasurePoolIsMinterAndBurner() public view {
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");

        bool isMinter = tldToken.hasRole(MINTER_ROLE, address(takasurePool));
        bool isBurner = tldToken.hasRole(BURNER_ROLE, address(takasurePool));
        // bool isMinter = tldToken.hasRole(MINTER_ROLE, address(proxy));
        // bool isBurner = tldToken.hasRole(BURNER_ROLE, address(proxy));

        assert(isMinter);
        assert(isBurner);
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testToken_mustRevertIfTryToMintToAddressZero() public {
        vm.prank(address(takasurePool));
        vm.expectRevert(TLDToken.TLDToken__NotZeroAddress.selector);
        tldToken.mint(address(0), MINT_AMOUNT);
    }

    function testToken_mustRevertIfTryToMintZero() public {
        vm.prank(address(takasurePool));
        vm.expectRevert(TLDToken.TLDToken__MustBeMoreThanZero.selector);
        tldToken.mint(user, 0);
    }

    function testToken_mustRevertIfTryToBurnZero() public {
        vm.prank(address(takasurePool));
        vm.expectRevert(TLDToken.TLDToken__MustBeMoreThanZero.selector);
        tldToken.burn(0);
    }

    function testToken_mustRevertIfTryToBurnMoreThanBalance() public {
        uint256 userBalance = tldToken.balanceOf(user);
        vm.prank(address(takasurePool));
        vm.expectRevert(
            abi.encodeWithSelector(
                TLDToken.TLDToken__BurnAmountExceedsBalance.selector,
                userBalance,
                MINT_AMOUNT
            )
        );
        tldToken.burn(MINT_AMOUNT);
    }
}
