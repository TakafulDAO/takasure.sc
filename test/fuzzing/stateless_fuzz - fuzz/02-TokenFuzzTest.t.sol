// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasureReserve} from "test/utils/TestDeployTakasureReserve.s.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";

contract TokenFuzzTest is Test {
    TestDeployTakasureReserve deployer;
    TakasureReserve takasureReserve;
    TSToken daoToken;
    EntryModule entryModule;
    MemberModule memberModule;
    address daoTokenAddress;
    address takasureReserveProxy;
    address entryModuleAddress;
    address memberModuleAddress;

    address public user = makeAddr("user");
    uint256 public constant MINT_AMOUNT = 1 ether;

    function setUp() public {
        deployer = new TestDeployTakasureReserve();
        (
            daoTokenAddress,
            ,
            takasureReserveProxy,
            entryModuleAddress,
            memberModuleAddress,
            ,
            ,
            ,
            ,
            ,

        ) = deployer.run();

        daoToken = TSToken(daoTokenAddress);
        takasureReserve = TakasureReserve(takasureReserveProxy);
        entryModule = EntryModule(entryModuleAddress);
        memberModule = MemberModule(memberModuleAddress);
    }

    function test_fuzz_onlyTakasurePoolIsBurnerAndMinter(
        address notMinter,
        address notBurner
    ) public view {
        // The input addresses must not be the same as the takasurePool address
        vm.assume(notMinter != entryModuleAddress);
        vm.assume(notBurner != entryModuleAddress);
        vm.assume(notMinter != memberModuleAddress);
        vm.assume(notBurner != memberModuleAddress);

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
        vm.assume(notMinter != entryModuleAddress);

        vm.prank(notMinter);
        vm.expectRevert();
        daoToken.mint(user, MINT_AMOUNT);
    }

    function test_fuzz_onlyBurnerCanBurn(address notBurner) public {
        // The input address must not be the same as the takasurePool address
        vm.assume(notBurner != entryModuleAddress);

        // Mint some tokens to the user
        vm.prank(entryModuleAddress);
        daoToken.mint(user, MINT_AMOUNT);

        vm.prank(notBurner);
        vm.expectRevert();
        daoToken.burn(MINT_AMOUNT);
    }
}
