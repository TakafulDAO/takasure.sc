// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeployTakaTokenAndTakasurePool} from "../../../scripts/foundry-deploy/01-taka-token-takasure-pool/DeployTakaTokenAndTakasurePool.s.sol";
import {HelperConfig} from "../../../scripts/foundry-deploy/HelperConfig.s.sol";
import {TakaToken} from "../../../contracts/token/TakaToken.sol";
import {TakasurePool} from "../../../contracts/token/TakasurePool.sol";

contract TakaTokenTest is Test {
    DeployTakaTokenAndTakasurePool deployer;
    TakaToken takaToken;
    TakasurePool takasurePool;
    HelperConfig config;

    address public admin = makeAddr("admin");
    address public user = makeAddr("user");

    uint256 public constant MINT_AMOUNT = 1 ether;

    event TakaTokenMinted(address indexed to, uint256 indexed amount);
    event TakaTokenBurned(address indexed from, uint256 indexed amount);

    function setUp() public {
        deployer = new DeployTakaTokenAndTakasurePool();
        (takaToken, takasurePool, ) = deployer.run();
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/
    function testTakasurePool_getTakaTokenAddress() public view {
        address takaTokenAddress = takasurePool.getTakaTokenAddress();
        assertEq(takaTokenAddress, address(takaToken));
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testTakasurePool_mustRevertIfTryToMintToAddressZero() public {
        vm.prank(address(admin));
        vm.expectRevert(TakasurePool.TakaSurePool__NotZeroAddress.selector);
        takasurePool.mintTakaToken(address(0), MINT_AMOUNT);
    }

    function testTakasurePool_mustRevertIfTryToBurnFromAddressZero() public {
        vm.prank(address(admin));
        vm.expectRevert(TakasurePool.TakaSurePool__NotZeroAddress.selector);
        takasurePool.burnTakaToken(MINT_AMOUNT, address(0));
    }

    function testTakasurePool_mustRevertIfTryToBurnMoreThanBalance() public {
        vm.prank(address(admin));
        vm.expectRevert(
            abi.encodeWithSelector(
                TakasurePool.TakaSurePool__BurnAmountExceedsBalance.selector,
                0,
                MINT_AMOUNT
            )
        );
        takasurePool.burnTakaToken(MINT_AMOUNT, user);
    }

    /*//////////////////////////////////////////////////////////////
                             MINT FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testTakasurePool_mintUpdateBalanceAndEmitEvent() public {
        uint256 userBalanceBefore = takaToken.balanceOf(user);
        uint256 userBalanceFromMappingBefore = takasurePool.getMintedTokensByUser(user);

        vm.prank(address(admin));

        // Expect to emit the event
        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit TakaTokenMinted(user, MINT_AMOUNT);
        takasurePool.mintTakaToken(user, MINT_AMOUNT);

        uint256 userBalanceAfter = takaToken.balanceOf(user);
        uint256 userBalanceFromMappingAfter = takasurePool.getMintedTokensByUser(user);

        // The mappings show the correct balance
        assertEq(userBalanceBefore, userBalanceFromMappingBefore);
        assertEq(userBalanceAfter, userBalanceFromMappingAfter);
        assert(userBalanceAfter > userBalanceBefore);
        assertEq(userBalanceAfter, MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                             BURN FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testTakasurePool_burnUpdateBalanceAndEmitEvent() public {
        uint256 burnAmount = MINT_AMOUNT / 2;

        // Mint some tokens to the user
        vm.prank(admin);
        takasurePool.mintTakaToken(user, MINT_AMOUNT);

        uint256 userBalanceFromMappingBefore = takasurePool.getMintedTokensByUser(user);
        // Allow takasurePool to spend the user's tokens
        vm.prank(user);
        takaToken.approve(address(takasurePool), MINT_AMOUNT);

        vm.prank(admin);
        // Expect to emit the event
        vm.expectEmit(true, true, false, false, address(takasurePool));
        emit TakaTokenBurned(user, burnAmount);
        takasurePool.burnTakaToken(burnAmount, user);

        uint256 userBalanceFromMappingAfter = takasurePool.getMintedTokensByUser(user);

        assert(userBalanceFromMappingBefore > userBalanceFromMappingAfter);
    }
}
