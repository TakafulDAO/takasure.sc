// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {TakaToken} from "../../../contracts/token/TakaToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../contracts/takasure/TakasurePool.sol";

contract TakaTokenTest is Test {
    DeployTokenAndPool deployer;
    TakaToken takaToken;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;

    address public admin = makeAddr("admin");
    address public user = makeAddr("user");

    uint256 public constant MINT_AMOUNT = 1 ether;

    event TakaTokenMinted(address indexed to, uint256 indexed amount);
    event TakaTokenBurned(address indexed from, uint256 indexed amount);

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (takaToken, proxy, , , ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                             MINT FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testTakaToken_mintUpdateBalanceAndEmitEvent() public {
        // Get users balance from the mapping and the balanceOf function to check if they match up
        uint256 userBalanceBefore = takaToken.balanceOf(user);

        vm.prank(address(takasurePool));

        // Event should be emitted
        vm.expectEmit(true, true, false, false, address(takaToken));
        emit TakaTokenMinted(user, MINT_AMOUNT);
        takaToken.mint(user, MINT_AMOUNT);

        // And the balance should be updated
        uint256 userBalanceAfter = takaToken.balanceOf(user);

        assert(userBalanceAfter > userBalanceBefore);

        assertEq(userBalanceAfter, MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                             BURN FUNCTION
    //////////////////////////////////////////////////////////////*/

    // function testTakaToken_burnUpdateBalanceAndEmitEvent() public {
    //     uint256 burnAmount = MINT_AMOUNT / 2;

    //     // Mint some tokens to the user
    //     vm.startPrank(address(takasurePool));
    //     takaToken.mint(address(takasurePool), MINT_AMOUNT);

    //     uint256 userBalanceFromMappingBefore = takaToken.getMintedTokensByUser(user);

    //     // Expect to emit the event
    //     vm.expectEmit(true, true, false, false, address(takaToken));
    //     emit TakaTokenBurned(user, burnAmount);
    //     takaToken.burn(burnAmount);
    //     vm.stopPrank();

    //     uint256 userBalanceFromMappingAfter = takaToken.getMintedTokensByUser(user);

    //     assert(userBalanceFromMappingBefore > userBalanceFromMappingAfter);
    // }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/
    function testTakaToken_TakasurePoolIsMinterAndBurner() public view {
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");

        bool isMinter = takaToken.hasRole(MINTER_ROLE, address(takasurePool));
        bool isBurner = takaToken.hasRole(BURNER_ROLE, address(takasurePool));
        // bool isMinter = takaToken.hasRole(MINTER_ROLE, address(proxy));
        // bool isBurner = takaToken.hasRole(BURNER_ROLE, address(proxy));

        assert(isMinter);
        assert(isBurner);
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testTakaToken_mustRevertIfTryToMintToAddressZero() public {
        vm.prank(address(takasurePool));
        vm.expectRevert(TakaToken.TakaToken__NotZeroAddress.selector);
        takaToken.mint(address(0), MINT_AMOUNT);
    }

    function testTakaToken_mustRevertIfTryToMintZero() public {
        vm.prank(address(takasurePool));
        vm.expectRevert(TakaToken.TakaToken__MustBeMoreThanZero.selector);
        takaToken.mint(user, 0);
    }

    function testTakaToken_mustRevertIfTryToBurnMoreThanBalance() public {
        uint256 userBalance = takaToken.balanceOf(user);
        vm.prank(address(takasurePool));
        vm.expectRevert(
            abi.encodeWithSelector(
                TakaToken.TakaToken__BurnAmountExceedsBalance.selector,
                userBalance,
                MINT_AMOUNT
            )
        );
        takaToken.burn(MINT_AMOUNT);
    }
}
