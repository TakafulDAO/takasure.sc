// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract RevShareNftTest is Test {
    TakasureReserve takasureReserve;
    AddressManager addressManager;
    RevShareNFT nft;
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");

    event OnTakasureReserveSet(
        address indexed oldTakasureReserve,
        address indexed newTakasureReserve
    );
    event OnBaseURISet(string indexed oldBaseUri, string indexed newBaseURI);
    event OnRevShareNFTMinted(address indexed owner, uint256 tokenId);
    event OnBatchRevShareNFTMinted(
        address indexed newOwner,
        uint256 initialTokenId,
        uint256 lastTokenId
    );

    function setUp() public {
        string
            memory baseURI = "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/";
        nft = new RevShareNFT(operator, baseURI);

        addressManager = new AddressManager();

        address token = makeAddr("token");

        address takasureReserveImplementation = address(new TakasureReserve());
        address takasureReserveAddress = UnsafeUpgrades.deployUUPSProxy(
            takasureReserveImplementation,
            abi.encodeCall(TakasureReserve.initialize, (token, address(addressManager)))
        );

        takasureReserve = TakasureReserve(takasureReserveAddress);
    }

    /*//////////////////////////////////////////////////////////////
                                  INIT
    //////////////////////////////////////////////////////////////*/

    function testNft_initialValues() public view {
        assertEq(nft.operator(), operator);
        assertEq(nft.MAX_SUPPLY(), 18_000);
        assertEq(nft.balanceOf(operator), nft.MAX_SUPPLY());
        assertEq(nft.totalSupply(), 9_179);
        assertEq(
            nft.baseURI(),
            "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function testNft_setTakasureReserve() public {
        vm.prank(nft.owner());
        vm.expectEmit(true, true, false, false, address(nft));
        emit OnTakasureReserveSet(address(0), address(takasureReserve));
        nft.setTakasureReserve(address(takasureReserve));
    }

    function testNft_takadaoNftsBaseUris() public {
        vm.prank(nft.owner());
        vm.expectEmit(true, true, false, false, address(nft));
        emit OnBaseURISet(
            "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/",
            "https://ipfs.io/ipfs/Qmb2yMfCt7zqCP5C2aoMAeYh9qyfabSTcb7URzV85zfZME/"
        );
        nft.setBaseURI("https://ipfs.io/ipfs/Qmb2yMfCt7zqCP5C2aoMAeYh9qyfabSTcb7URzV85zfZME/");

        assertEq(
            nft.tokenURI(0),
            "https://ipfs.io/ipfs/Qmb2yMfCt7zqCP5C2aoMAeYh9qyfabSTcb7URzV85zfZME/0.json"
        );
    }

    /*//////////////////////////////////////////////////////////////
                              SINGLE MINT
    //////////////////////////////////////////////////////////////*/

    function testNft_mintMustRevertIfNewOwnerIsAddressZero() public {
        vm.prank(nft.owner());
        vm.expectRevert();
        nft.mint(address(0));
    }

    function testNft_mintSingleNftUpdatesBalanceAndEmitEvent() public {
        uint256 latestTokenIdBefore = nft.totalSupply();
        uint256 aliceBalanceBefore = nft.balanceOf(alice);

        vm.prank(nft.owner());
        vm.expectEmit(true, false, false, false, address(nft));
        emit OnRevShareNFTMinted(alice, latestTokenIdBefore + 1);
        nft.mint(alice);

        assertEq(nft.totalSupply(), latestTokenIdBefore + 1);
        assertEq(aliceBalanceBefore, 0);
        assertEq(nft.balanceOf(alice), 1);
    }

    function testNft_callsExternalContract() public {
        vm.startPrank(nft.owner());
        nft.setTakasureReserve(address(takasureReserve));
        nft.mint(alice);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               BATCH MINT
    //////////////////////////////////////////////////////////////*/

    function testNft_batchMintRevertIfIsAddressZero() public {
        vm.prank(nft.owner());
        vm.expectRevert();
        nft.batchMint(address(0), 2);
    }

    function testNft_batchMintRevertIfMintOnlyOneIsAddressZero() public {
        vm.prank(nft.owner());
        vm.expectRevert(RevShareNFT.RevShareNFT__BatchMintMoreThanOne.selector);
        nft.batchMint(alice, 1);
    }

    function testNft_batchMintTokens() public {
        assertEq(nft.balanceOf(alice), 0);

        vm.prank(nft.owner());
        vm.expectEmit(true, false, false, false, address(nft));
        emit OnBatchRevShareNFTMinted(alice, 9179, 9182);
        nft.batchMint(alice, 3);

        assertEq(nft.balanceOf(alice), 3);
        assertEq(nft.totalSupply(), 9182);
    }

    /*//////////////////////////////////////////////////////////////
                               TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function testNft_transferNftRevertsIfRevShareModuleNotSetUp() public {
        vm.prank(operator);
        vm.expectRevert(RevShareNFT.RevShareNFT__RevShareModuleNotSetUp.selector);
        nft.transfer(alice, 1);
    }

    // function testNft_transferNft() public {
    //     assertEq(nft.balanceOf(operator), 18_000);
    //     assertEq(nft.balanceOf(alice), 0);

    //     vm.prank(operator);
    //     nft.transfer(alice, 1);

    //     assertEq(nft.balanceOf(operator), 17_999);
    //     assertEq(nft.balanceOf(alice), 1);
    // }

    // function testNft_transferFromNft() public {
    //     address bob = makeAddr("bob");
    //     address charlie = makeAddr("charlie");

    //     assertEq(nft.balanceOf(operator), 18_000);
    //     assertEq(nft.balanceOf(alice), 0);
    //     assertEq(nft.balanceOf(bob), 0);
    //     assertEq(nft.balanceOf(charlie), 0);

    //     vm.prank(operator);
    //     nft.transfer(alice, 1);

    //     assertEq(nft.balanceOf(operator), 17_999);
    //     assertEq(nft.balanceOf(alice), 1);
    //     assertEq(nft.balanceOf(bob), 0);
    //     assertEq(nft.balanceOf(charlie), 0);

    //     vm.prank(alice);
    //     nft.setApprovalForAll(bob, true);

    //     vm.prank(bob);
    //     nft.transferFrom(alice, charlie, 1);

    //     assertEq(nft.balanceOf(operator), 17_999);
    //     assertEq(nft.balanceOf(alice), 0);
    //     assertEq(nft.balanceOf(bob), 0);
    //     assertEq(nft.balanceOf(charlie), 1);
    // }
}
