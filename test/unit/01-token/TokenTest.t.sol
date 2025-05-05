// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

contract TokenTest is Test {
    TestDeployProtocol deployer;
    TSToken daoToken;
    TakasureReserve takasureReserve;
    EntryModule entryModule;
    HelperConfig helperConfig;
    address takasureReserveProxy;
    address entryModuleAddress;

    address public admin = makeAddr("admin");
    address public user = makeAddr("user");

    uint256 public constant MINT_AMOUNT = 1 ether;

    event OnTokenMinted(address indexed to, uint256 indexed amount);
    event OnTokenBurned(address indexed from, uint256 indexed amount);
    event OnTransferAllowedSet(bool transferAllowed);

    function setUp() public {
        // deployer = new TestDeployTakasure();
        // (daoToken, proxy, , ) = deployer.run();
        deployer = new TestDeployProtocol();
        (, , takasureReserveProxy, , entryModuleAddress, , , , , , helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        admin = config.daoMultisig;

        entryModule = EntryModule(entryModuleAddress);

        daoToken = TSToken(TakasureReserve(takasureReserveProxy).getReserveValues().daoToken);
    }

    /*//////////////////////////////////////////////////////////////
                             MINT FUNCTION
    //////////////////////////////////////////////////////////////*/

    function testToken_mintUpdateBalanceAndEmitEvent() public {
        // Get users balance from the mapping and the balanceOf function to check if they match up
        uint256 userBalanceBefore = daoToken.balanceOf(user);

        vm.prank(address(entryModule));

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
        vm.startPrank(address(entryModule));
        daoToken.mint(address(entryModule), MINT_AMOUNT);
        uint256 balanceBefore = daoToken.balanceOf(address(entryModule));

        // Expect to emit the event
        vm.expectEmit(true, true, false, false, address(daoToken));
        emit OnTokenBurned(address(entryModule), burnAmount);
        daoToken.burn(burnAmount);
        uint256 balanceAfter = daoToken.balanceOf(address(entryModule));
        vm.stopPrank();
        assert(balanceBefore > balanceAfter);
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
        daoToken.burn(0);
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
        daoToken.burn(MINT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                               TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function testToken_setTransferAllowed() public {
        assert(!daoToken.transferAllowed());

        vm.prank(admin);
        vm.expectEmit(false, false, false, false, address(daoToken));
        emit OnTransferAllowedSet(true);
        daoToken.setTransferAllowed(true);

        assert(daoToken.transferAllowed());
    }

    function testToken_mustRevertIfTransferNotAllowed() public {
        vm.prank(address(entryModule));
        daoToken.mint(user, MINT_AMOUNT);

        address alice = makeAddr("alice");

        vm.prank(user);
        vm.expectRevert(TSToken.Token__TransferNotAllowed.selector);
        daoToken.transfer(alice, MINT_AMOUNT);
    }

    function testToken_mustRevertIfTransferFromNotAllowed() public {
        vm.prank(address(entryModule));
        daoToken.mint(user, MINT_AMOUNT);

        address alice = makeAddr("alice");
        address spender = makeAddr("spender");

        vm.prank(user);
        daoToken.approve(spender, MINT_AMOUNT);

        vm.prank(spender);
        vm.expectRevert(TSToken.Token__TransferNotAllowed.selector);
        daoToken.transferFrom(user, alice, MINT_AMOUNT);
    }

    function testToken_transfer() public {
        assert(!daoToken.transferAllowed());

        vm.prank(address(entryModule));
        daoToken.mint(user, MINT_AMOUNT);

        address alice = makeAddr("alice");
        assert(daoToken.balanceOf(user) == MINT_AMOUNT);
        assert(daoToken.balanceOf(alice) == 0);

        vm.prank(admin);
        daoToken.setTransferAllowed(true);

        vm.prank(user);
        daoToken.transfer(alice, MINT_AMOUNT);

        assert(daoToken.balanceOf(user) == 0);
        assertEq(daoToken.balanceOf(alice), MINT_AMOUNT);
    }

    function testToken_transferFrom() public {
        assert(!daoToken.transferAllowed());

        vm.prank(address(entryModule));
        daoToken.mint(user, MINT_AMOUNT);

        vm.prank(admin);
        daoToken.setTransferAllowed(true);

        address spender = makeAddr("spender");

        vm.prank(user);
        daoToken.approve(spender, MINT_AMOUNT);
        assert(daoToken.allowance(user, spender) == MINT_AMOUNT);

        address alice = makeAddr("alice");
        assert(daoToken.balanceOf(user) == MINT_AMOUNT);
        assert(daoToken.balanceOf(alice) == 0);

        vm.prank(spender);
        daoToken.transferFrom(user, alice, MINT_AMOUNT);

        assert(daoToken.balanceOf(user) == 0);
        assertEq(daoToken.balanceOf(alice), MINT_AMOUNT);
        assert(daoToken.allowance(user, spender) == 0);
    }
}
