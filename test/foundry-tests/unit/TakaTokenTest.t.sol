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

    address public user = makeAddr("user");

    uint256 public constant MINT_AMOUNT = 1 ether;

    function setUp() public {
        deployer = new DeployTakaTokenAndTakasurePool();
        (takaToken, takasurePool, ) = deployer.run();
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/
    function testTakaToken_takasurePoolIsMinterAndBurner() public view {
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");

        bool isMinter = takaToken.hasRole(MINTER_ROLE, address(takasurePool));
        bool isBurner = takaToken.hasRole(BURNER_ROLE, address(takasurePool));

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

    function testTakaToken_mustRevertIfTryToBurnZero() public {
        vm.prank(address(takasurePool));
        vm.expectRevert(TakaToken.TakaToken__MustBeMoreThanZero.selector);
        takaToken.burn(0);
    }

    function testTakaToken_mustRevertIfTtryToBurnMoreThanBalance() public {
        vm.prank(address(takasurePool));
        vm.expectRevert(TakaToken.TakaToken__BurnAmountExceedsBalance.selector);
        takaToken.burn(MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                             MINT FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testTakaToken_mint() public {
        vm.prank(address(takasurePool));
        takaToken.mint(user, MINT_AMOUNT);
        assertEq(takaToken.balanceOf(user), MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                             BURN FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testTakaToken_burn() public {
        uint256 amountToBurn = MINT_AMOUNT / 2;

        vm.startPrank(address(takasurePool));
        takaToken.mint(address(takasurePool), MINT_AMOUNT);

        takaToken.burn(amountToBurn);
        vm.stopPrank();

        assertEq(takaToken.balanceOf(address(takasurePool)), MINT_AMOUNT - amountToBurn);
    }
}
