// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {DeployTakaTokenAndTakasurePool} from "../../../scripts/foundry-deploy/01-taka-token-takasure-pool/DeployTakaTokenAndTakasurePool.s.sol";
import {HelperConfig} from "../../../scripts/foundry-deploy/HelperConfig.s.sol";
import {TakaToken} from "../../../contracts/token/TakaToken.sol";
import {TakasurePool} from "../../../contracts/token/TakasurePool.sol";

contract TakaTokenFuzzTest is Test {
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

    function test_fuzz_onlyTakasurePoolIsBurnerAndMinter(
        address notMinter,
        address notBurner
    ) public view {
        bytes32 MINTER_ROLE = keccak256("MINTER_ROLE");
        bytes32 BURNER_ROLE = keccak256("BURNER_ROLE");

        vm.assume(notMinter != address(takasurePool));
        vm.assume(notBurner != address(takasurePool));

        bool isMinter = takaToken.hasRole(MINTER_ROLE, notMinter);
        bool isBurner = takaToken.hasRole(BURNER_ROLE, notBurner);

        assert(!isMinter);
        assert(!isBurner);
    }

    function test_fuzz_onlyMinterCanMint(address minter) public {
        vm.assume(minter != address(takasurePool));
        vm.prank(minter);
        vm.expectRevert();
        takaToken.mint(user, MINT_AMOUNT);
    }

    function test_fuzz_onlyBurnerCanBurn(address burner) public {
        vm.assume(burner != address(takasurePool));

        vm.prank(address(takasurePool));
        takaToken.mint(address(takasurePool), MINT_AMOUNT);

        vm.prank(burner);
        vm.expectRevert();
        takaToken.burn(MINT_AMOUNT);
    }
}
