// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeployPoolAndModules} from "../../../scripts/foundry-deploy/DeployPoolAndModules.s.sol";
import {TakasurePool} from "../../../contracts/token/TakasurePool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MembersModule} from "../../../contracts/modules/MembersModule.sol";

contract TakasurePoolTest is Test {
    DeployPoolAndModules deployer;
    TakasurePool takasurePool;
    MembersModule membersModule;
    ERC1967Proxy proxy;

    address public admin = makeAddr("admin");
    address public user = makeAddr("user");

    uint256 public constant MINT_AMOUNT = 1 ether;

    event TakaTokenMinted(address indexed to, uint256 indexed amount);
    event TakaTokenBurned(address indexed from, uint256 indexed amount);

    function setUp() public {
        deployer = new DeployPoolAndModules();
        (takasurePool, proxy, , , ) = deployer.run();

        membersModule = MembersModule(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/
    function testTakasurePool_membersModuleIsMinterAndBurner() public view {
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");

        bool isMinter = takasurePool.hasRole(MINTER_ROLE, address(membersModule));
        bool isBurner = takasurePool.hasRole(BURNER_ROLE, address(membersModule));
        // bool isMinter = takasurePool.hasRole(MINTER_ROLE, address(proxy));
        // bool isBurner = takasurePool.hasRole(BURNER_ROLE, address(proxy));

        assert(isMinter);
        assert(isBurner);
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testTakasurePool_mustRevertIfTryToMintToAddressZero() public {
        vm.prank(address(membersModule));
        vm.expectRevert(TakasurePool.TakasurePool__NotZeroAddress.selector);
        takasurePool.mint(address(0), MINT_AMOUNT);
    }

    function testTakasurePool_mustRevertIfTryToMintZero() public {
        vm.prank(address(membersModule));
        vm.expectRevert(TakasurePool.TakasurePool__MustBeMoreThanZero.selector);
        takasurePool.mint(user, 0);
    }

    function testTakasurePool_mustRevertIfTryToBurnFromAddressZero() public {
        vm.prank(address(membersModule));
        vm.expectRevert(TakasurePool.TakasurePool__NotZeroAddress.selector);
        takasurePool.burnTokens(address(0), MINT_AMOUNT);
    }

    function testTakasurePool_mustRevertIfTryToBurnMoreThanBalance() public {
        uint256 userBalance = takasurePool.getMintedTokensByUser(user);
        vm.prank(address(membersModule));
        vm.expectRevert(
            abi.encodeWithSelector(
                TakasurePool.TakaSurePool__BurnAmountExceedsBalance.selector,
                userBalance,
                MINT_AMOUNT
            )
        );
        takasurePool.burnTokens(user, MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                             MINT FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testTakasurePool_mintUpdateBalanceAndEmitEvent() public {
        // Get users balance from the mapping and the balanceOf function to check if they match up
        uint256 userBalanceBefore = takasurePool.balanceOf(user);
        uint256 userBalanceFromMappingBefore = takasurePool.getMintedTokensByUser(user);

        vm.prank(address(membersModule));

        // Event should be emitted
        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit TakaTokenMinted(user, MINT_AMOUNT);
        takasurePool.mint(user, MINT_AMOUNT);

        // And the balance should be updated
        uint256 userBalanceAfter = takasurePool.balanceOf(user);
        uint256 userBalanceFromMappingAfter = takasurePool.getMintedTokensByUser(user);

        assert(userBalanceAfter > userBalanceBefore);

        assertEq(userBalanceAfter, MINT_AMOUNT);

        // Check if he mappings show the correct balance
        assertEq(userBalanceBefore, userBalanceFromMappingBefore);
        assertEq(userBalanceAfter, userBalanceFromMappingAfter);
    }

    /*//////////////////////////////////////////////////////////////
                             BURN FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testTakasurePool_burnUpdateBalanceAndEmitEvent() public {
        uint256 burnAmount = MINT_AMOUNT / 2;

        // Mint some tokens to the user
        vm.prank(address(membersModule));
        takasurePool.mint(user, MINT_AMOUNT);

        uint256 userBalanceFromMappingBefore = takasurePool.getMintedTokensByUser(user);
        // Allow takasurePool to spend the user's tokens
        vm.prank(user);
        takasurePool.approve(address(membersModule), burnAmount);

        vm.prank(address(membersModule));
        // Expect to emit the event
        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit TakaTokenBurned(user, burnAmount);
        takasurePool.burnTokens(user, burnAmount);

        uint256 userBalanceFromMappingAfter = takasurePool.getMintedTokensByUser(user);

        assert(userBalanceFromMappingBefore > userBalanceFromMappingAfter);
    }
}
