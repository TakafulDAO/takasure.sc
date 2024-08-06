// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";

contract TokenFuzzTest is Test {
    TestDeployTakasure deployer;
    TSToken daoToken;
    TakasurePool takasurePool;
    address proxy;

    address public user = makeAddr("user");
    uint256 public constant MINT_AMOUNT = 1 ether;

    function setUp() public {
        deployer = new TestDeployTakasure();
        (daoToken, proxy, , ) = deployer.run();

        takasurePool = TakasurePool(address(proxy));
    }

    function test_fuzz_onlyTakasurePoolIsBurnerAndMinter(
        address notMinter,
        address notBurner
    ) public view {
        // The input addresses must not be the same as the takasurePool address
        vm.assume(notMinter != address(takasurePool));
        vm.assume(notBurner != address(takasurePool));

        // Roles to check
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");

        bool isMinter = daoToken.hasRole(MINTER_ROLE, notMinter);
        bool isBurner = daoToken.hasRole(BURNER_ROLE, notBurner);

        assert(!isMinter);
        assert(!isBurner);
    }

    function test_fuzz_onlyMinterCanMint(address notMinter) public {
        // The input address must not be the same as the takasurePool address
        vm.assume(notMinter != address(takasurePool));

        vm.prank(notMinter);
        vm.expectRevert();
        daoToken.mint(user, MINT_AMOUNT);
    }

    function test_fuzz_onlyBurnerCanBurn(address notBurner) public {
        // The input address must not be the same as the takasurePool address
        vm.assume(notBurner != address(takasurePool));

        // Mint some tokens to the user
        vm.prank(address(takasurePool));
        daoToken.mint(user, MINT_AMOUNT);

        vm.prank(notBurner);
        vm.expectRevert();
        daoToken.burn(MINT_AMOUNT);
    }
}
