// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract RevShareNftFuzzTest is Test {
    RevShareNFT nft;
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");

    function setUp() public {
        string
            memory baseURI = "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/";
        address nftImplementation = address(new RevShareNFT());
        address nftAddress = UnsafeUpgrades.deployUUPSProxy(
            nftImplementation,
            abi.encodeCall(RevShareNFT.initialize, (baseURI))
        );
        nft = RevShareNFT(nftAddress);
    }

    function testUpgradeRevertsIfCallerIsInvalid(address caller) public {
        vm.assume(caller != nft.owner());
        address newImpl = makeAddr("newImpl");

        vm.prank(caller);
        vm.expectRevert();
        nft.upgradeToAndCall(newImpl, "");
    }

    function testSetAddressManagerIfCallerIsInvalid(address caller) public {
        vm.assume(caller != nft.owner());

        vm.prank(caller);
        vm.expectRevert();
        nft.setAddressManager(makeAddr("newAddressManager"));
    }

    function testSetBaseURIIfCallerIsInvalid(address caller) public {
        vm.assume(caller != nft.owner());

        vm.prank(caller);
        vm.expectRevert();
        nft.setBaseURI("new URI");
    }

    function testMintIfCallerIsInvalid(address caller) public {
        vm.assume(caller != nft.owner());

        vm.prank(caller);
        vm.expectRevert();
        nft.mint(alice);
    }

    function testBatchMintIfCallerIsInvalid(address caller) public {
        vm.assume(caller != nft.owner());

        vm.prank(caller);
        vm.expectRevert();
        nft.batchMint(alice, 5);
    }
}
