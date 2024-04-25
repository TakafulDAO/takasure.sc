// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DeployPoolAndModules} from "../../../scripts/foundry-deploy/DeployPoolAndModules.s.sol";
import {TakasurePool} from "../../../contracts/token/TakasurePool.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MembersModule} from "../../../contracts/modules/MembersModule.sol";

contract TakaTokenFuzzTest is Test {
    DeployPoolAndModules deployer;
    TakasurePool takasurePool;
    MembersModule membersModule;
    ERC1967Proxy proxy;

    address public user = makeAddr("user");
    uint256 public constant MINT_AMOUNT = 1 ether;

    function setUp() public {
        deployer = new DeployPoolAndModules();
        (takasurePool, proxy, , , ) = deployer.run();

        membersModule = MembersModule(address(proxy));
    }

    function test_fuzz_onlyMembersModuleIsBurnerAndMinter(
        address notMinter,
        address notBurner
    ) public view {
        // The input addresses must not be the same as the membersModule address
        vm.assume(notMinter != address(membersModule));
        vm.assume(notBurner != address(membersModule));

        // Roles to check
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");

        bool isMinter = takasurePool.hasRole(MINTER_ROLE, notMinter);
        bool isBurner = takasurePool.hasRole(BURNER_ROLE, notBurner);

        assert(!isMinter);
        assert(!isBurner);
    }

    function test_fuzz_onlyMinterCanMint(address minter) public {
        // The input address must not be the same as the membersModule address
        vm.assume(minter != address(membersModule));

        vm.prank(minter);
        vm.expectRevert();
        takasurePool.mint(user, MINT_AMOUNT);
    }

    function test_fuzz_onlyBurnerCanBurn(address burner) public {
        // The input address must not be the same as the membersModule address
        vm.assume(burner != address(membersModule));

        // Mint some tokens to the user
        vm.prank(address(membersModule));
        takasurePool.mint(user, MINT_AMOUNT);

        vm.prank(burner);
        vm.expectRevert();
        takasurePool.burnTokens(user, MINT_AMOUNT);
    }
}
