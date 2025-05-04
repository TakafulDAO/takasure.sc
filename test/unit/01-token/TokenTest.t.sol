// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";

contract TokenTest is Test {
    TestDeployProtocol deployer;
    TSToken daoToken;
    TakasureReserve takasureReserve;
    EntryModule entryModule;
    address takasureReserveProxy;
    address entryModuleAddress;

    address public admin = makeAddr("admin");
    address public user = makeAddr("user");

    uint256 public constant MINT_AMOUNT = 1 ether;

    event OnTokenMinted(address indexed to, uint256 indexed amount);
    event OnTokenBurned(address indexed from, uint256 indexed amount);

    function setUp() public {
        // deployer = new TestDeployTakasure();
        // (daoToken, proxy, , ) = deployer.run();
        deployer = new TestDeployProtocol();
        (, , takasureReserveProxy, , entryModuleAddress, , , , , , ) = deployer.run();

        entryModule = EntryModule(entryModuleAddress);

        daoToken = TSToken(TakasureReserve(takasureReserveProxy).getReserveValues().daoToken);
    }

    /*//////////////////////////////////////////////////////////////
                             MINT FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testToken_mintUpdateBalanceAndEmitEvent() public {
        // Get users balance from the mapping and the balanceOf function to check if they match up
        uint256 userBalanceBefore = daoToken.balanceOf(user);
        assertEq(daoToken.totalSupply(), 0);

        vm.prank(address(entryModule));

        // Event should be emitted
        vm.expectEmit(true, true, false, false, address(daoToken));
        emit OnTokenMinted(user, MINT_AMOUNT);
        daoToken.mint(user, MINT_AMOUNT);

        // And the balance should be updated
        uint256 userBalanceAfter = daoToken.balanceOf(user);

        assert(userBalanceAfter > userBalanceBefore);

        assertEq(userBalanceAfter, MINT_AMOUNT);
        assertEq(daoToken.totalSupply(), MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                             BURN FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testToken_burnReverts() public {
        uint256 burnAmount = MINT_AMOUNT / 2;

        // Mint some tokens to the user
        vm.startPrank(address(entryModule));
        daoToken.mint(address(entryModule), MINT_AMOUNT);
        uint256 balanceBefore = daoToken.balanceOf(address(entryModule));

        // Expect to emit the event
        vm.expectRevert(TSToken.Token__BurnsNotAllowed.selector);
        daoToken.burn(burnAmount);
        vm.stopPrank();

        uint256 balanceAfter = daoToken.balanceOf(address(entryModule));
        assertEq(balanceBefore, balanceAfter);
    }

    function testToken_burnFromUpdateBalanceAndEmitEvent() public {
        uint256 burnAmount = MINT_AMOUNT / 2;

        assertEq(daoToken.totalSupply(), 0);

        // Mint some tokens to the user
        vm.prank(address(entryModule));
        daoToken.mint(user, MINT_AMOUNT);

        assertEq(daoToken.totalSupply(), MINT_AMOUNT);

        vm.prank(user);
        daoToken.approve(address(entryModule), MINT_AMOUNT);

        uint256 balanceBefore = daoToken.balanceOf(user);

        vm.prank(address(entryModule));
        // Expect to emit the event
        vm.expectEmit(true, true, false, false, address(daoToken));
        emit OnTokenBurned(user, burnAmount);
        daoToken.burnFrom(user, burnAmount);

        uint256 balanceAfter = daoToken.balanceOf(address(entryModule));

        assert(balanceBefore > balanceAfter);
        assertEq(daoToken.totalSupply(), MINT_AMOUNT - burnAmount);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/
    function testToken_EntryModuleIsMinterAndBurner() public view {
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");

        bool isMinter = daoToken.hasRole(MINTER_ROLE, address(entryModule));
        bool isBurner = daoToken.hasRole(BURNER_ROLE, address(entryModule));

        assert(isMinter);
        assert(isBurner);
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/

    function testToken_mustRevertIfTryToMintToAddressZero() public {
        vm.prank(address(entryModule));
        vm.expectRevert(TSToken.Token__NotZeroAddress.selector);
        daoToken.mint(address(0), MINT_AMOUNT);
    }

    function testToken_mustRevertIfTryToMintZero() public {
        vm.prank(address(entryModule));
        vm.expectRevert(TSToken.Token__MustBeMoreThanZero.selector);
        daoToken.mint(user, 0);
    }

    function testToken_mustRevertIfTryToBurnZero() public {
        vm.prank(address(entryModule));
        vm.expectRevert(TSToken.Token__MustBeMoreThanZero.selector);
        daoToken.burnFrom(user, 0);
    }

    function testToken_mustRevertIfTryToBurnMoreThanBalance() public {
        uint256 userBalance = daoToken.balanceOf(user);
        vm.prank(address(entryModule));
        vm.expectRevert(
            abi.encodeWithSelector(
                TSToken.Token__BurnAmountExceedsBalance.selector,
                userBalance,
                MINT_AMOUNT
            )
        );
        daoToken.burnFrom(user, MINT_AMOUNT);
    }
}
