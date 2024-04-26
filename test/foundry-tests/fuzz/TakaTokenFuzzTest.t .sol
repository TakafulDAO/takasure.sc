// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Test, console} from "forge-std/Test.sol";
import {DeployTokenAndPool} from "../../../scripts/foundry-deploy/DeployTokenAndPool.s.sol";
import {TakaToken} from "../../../contracts/token/TakaToken.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TakasurePool} from "../../../contracts/takasure/TakasurePool.sol";

contract TakaTokenFuzzTest is Test {
    DeployTokenAndPool deployer;
    TakaToken takaToken;
    TakasurePool takasurePool;
    ERC1967Proxy proxy;

    address public user = makeAddr("user");
    uint256 public constant MINT_AMOUNT = 1 ether;

    function setUp() public {
        deployer = new DeployTokenAndPool();
        (takaToken, proxy, , , ) = deployer.run();

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

        bool isMinter = takaToken.hasRole(MINTER_ROLE, notMinter);
        bool isBurner = takaToken.hasRole(BURNER_ROLE, notBurner);

        assert(!isMinter);
        assert(!isBurner);
    }

    function test_fuzz_onlyMinterCanMint(address minter) public {
        // The input address must not be the same as the takasurePool address
        vm.assume(minter != address(takasurePool));

        vm.prank(minter);
        vm.expectRevert();
        takaToken.mint(user, MINT_AMOUNT);
    }

    function test_fuzz_onlyBurnerCanBurn(address burner) public {
        // The input address must not be the same as the takasurePool address
        vm.assume(burner != address(takasurePool));

        // Mint some tokens to the user
        vm.prank(address(takasurePool));
        takaToken.mint(user, MINT_AMOUNT);

        vm.prank(burner);
        vm.expectRevert();
        takaToken.burn(MINT_AMOUNT);
    }
}
