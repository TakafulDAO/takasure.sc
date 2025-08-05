// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

contract RevShareNftTest is Test {
    RevShareNFT nft;
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");

    event OnAddressManagerSet(address indexed oldAddressManager, address indexed newAddressManager);
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
        address nftImplementation = address(new RevShareNFT());
        address nftAddress = UnsafeUpgrades.deployUUPSProxy(
            nftImplementation,
            abi.encodeCall(RevShareNFT.initialize, (baseURI))
        );
        nft = RevShareNFT(nftAddress);
    }

    /*//////////////////////////////////////////////////////////////
                                  INIT
    //////////////////////////////////////////////////////////////*/

    function testNft_initialValues() public view {
        assertEq(nft.MAX_SUPPLY(), 8_820);
        assertEq(nft.totalSupply(), 0);
        assertEq(
            nft.baseURI(),
            "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/"
        );
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function testNft_setAddressManager() public {
        address addressManager = makeAddr("addressManager");
        vm.prank(nft.owner());
        vm.expectEmit(true, true, false, false, address(nft));
        emit OnAddressManagerSet(address(0), address(addressManager));
        nft.setAddressManager(address(addressManager));
    }

    function testNft_takadaoNftsBaseUris() public {
        vm.startPrank(nft.owner());
        vm.expectEmit(true, true, false, false, address(nft));
        emit OnBaseURISet(
            "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/",
            "https://ipfs.io/ipfs/Qmb2yMfCt7zqCP5C2aoMAeYh9qyfabSTcb7URzV85zfZME/"
        );
        nft.setBaseURI("https://ipfs.io/ipfs/Qmb2yMfCt7zqCP5C2aoMAeYh9qyfabSTcb7URzV85zfZME/");

        vm.expectRevert();
        nft.tokenURI(0);

        nft.mint(alice);

        vm.stopPrank();

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
        emit OnBatchRevShareNFTMinted(alice, 0, 2);
        nft.batchMint(alice, 3);

        assertEq(nft.balanceOf(alice), 3);
        assertEq(nft.totalSupply(), 3);
    }

    /*//////////////////////////////////////////////////////////////
                               TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function testNft_transferNftRevertsIfRevShareModuleNotSetUp() public {
        vm.prank(alice);
        vm.expectRevert(RevShareNFT.RevShareNFT__RevShareModuleNotSetUp.selector);
        nft.transfer(alice, 1);
    }
}
