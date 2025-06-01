// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {TSToken} from "contracts/token/TSToken.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {MemberModule} from "contracts/modules/MemberModule.sol";

contract TokenFuzzTest is Test {
    TestDeployProtocol deployer;
    TakasureReserve takasureReserve;
    TSToken daoToken;
    SubscriptionModule subscriptionModule;
    MemberModule memberModule;
    address daoTokenAddress;
    address takasureReserveProxy;
    address subscriptionModuleAddress;
    address memberModuleAddress;

    address public user = makeAddr("user");
    uint256 public constant MINT_AMOUNT = 1 ether;

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            daoTokenAddress,
            ,
            takasureReserveProxy,
            ,
            subscriptionModuleAddress,
            ,
            memberModuleAddress,
            ,
            ,
            ,
            ,

        ) = deployer.run();

        daoToken = TSToken(daoTokenAddress);
        takasureReserve = TakasureReserve(takasureReserveProxy);
        subscriptionModule = SubscriptionModule(subscriptionModuleAddress);
        memberModule = MemberModule(memberModuleAddress);
    }

    function test_fuzz_onlyTakasurePoolIsBurnerAndMinter(
        address notMinter,
        address notBurner
    ) public view {
        // The input addresses must not be the same as the takasurePool address
        vm.assume(notMinter != subscriptionModuleAddress);
        vm.assume(notBurner != subscriptionModuleAddress);
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
        vm.assume(notMinter != subscriptionModuleAddress);

        vm.prank(notMinter);
        vm.expectRevert();
        daoToken.mint(user, MINT_AMOUNT);
    }

    function test_fuzz_onlyBurnerCanBurn(address notBurner) public {
        // The input address must not be the same as the takasurePool address
        vm.assume(notBurner != subscriptionModuleAddress);

        // Mint some tokens to the user
        vm.prank(subscriptionModuleAddress);
        daoToken.mint(user, MINT_AMOUNT);

        vm.prank(notBurner);
        vm.expectRevert();
        daoToken.burn(MINT_AMOUNT);
    }
}
