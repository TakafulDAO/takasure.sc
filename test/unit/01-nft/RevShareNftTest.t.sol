// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ProtocolAddress, ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";
import {RevShareModuleMock} from "test/mocks/RevShareModuleMock.sol";

contract RevShareNftTest is Test {
    RevShareNFT nft;
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

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
            abi.encodeCall(RevShareNFT.initialize, (baseURI, msg.sender))
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

    function testNft_tokenURIEmptyWhenBaseURINotSet() public {
        address impl = address(new RevShareNFT());
        RevShareNFT noBaseUri = RevShareNFT(
            UnsafeUpgrades.deployUUPSProxy(
                impl,
                abi.encodeCall(RevShareNFT.initialize, ("", msg.sender))
            )
        );

        vm.prank(noBaseUri.owner());
        noBaseUri.mint(alice);

        assertEq(noBaseUri.tokenURI(0), "");
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

    function testNft_mintStoresPioneerMintedAt() public {
        address failingManager = address(0xFEED);

        _mockAddressManagerRevert(failingManager);

        vm.prank(nft.owner());
        nft.setAddressManager(failingManager);

        vm.prank(nft.owner());
        nft.mint(alice);

        uint256 timestamp = nft.pioneerMintedAt(alice, 0);
        assertGt(timestamp, 0);
        assertLe(timestamp, block.timestamp);
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

    function testNft_batchMintStoresPioneerMintedAt() public {
        address failingManager = address(0xABCD);
        _mockAddressManagerRevert(failingManager);

        vm.prank(nft.owner());
        nft.setAddressManager(failingManager);

        vm.prank(nft.owner());
        nft.batchMint(alice, 3);

        for (uint256 i = 0; i < 3; ++i) {
            assertGt(nft.pioneerMintedAt(alice, i), 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                               TRANSFERS
    //////////////////////////////////////////////////////////////*/

    function testNft_transferRevertsIfRevModuleNotSet() public {
        vm.prank(nft.owner());
        nft.mint(alice);

        vm.prank(alice);
        vm.expectRevert(RevShareNFT.RevShareNFT__RevShareModuleNotSetUp.selector);
        nft.transfer(bob, 0);
    }

    function testNft_transferFromRevertsIfRevModuleNotSet() public {
        vm.prank(nft.owner());
        nft.mint(alice);

        vm.prank(alice);
        nft.approve(bob, 0);

        vm.prank(bob);
        vm.expectRevert(RevShareNFT.RevShareNFT__RevShareModuleNotSetUp.selector);
        nft.transferFrom(alice, bob, 0);
    }

    function testNft_transferWorksIfRevModuleSet() public {
        RevShareModuleMock rev = new RevShareModuleMock();
        address mockManager = address(0xCAFE);

        _mockAddressManagerReturn(mockManager, address(rev));

        vm.prank(nft.owner());
        nft.setAddressManager(mockManager);

        vm.prank(nft.owner());
        nft.mint(alice);

        vm.prank(alice);
        nft.transfer(bob, 0);

        assertEq(nft.ownerOf(0), bob);
        assertEq(rev.lastUpdated(), bob);
    }

    function testNft_transferFromWorksIfRevModuleSet() public {
        RevShareModuleMock rev = new RevShareModuleMock();
        address mockManager = address(0xBEEF);

        _mockAddressManagerReturn(mockManager, address(rev));

        vm.prank(nft.owner());
        nft.setAddressManager(mockManager);

        vm.prank(nft.owner());
        nft.mint(alice);

        vm.prank(alice);
        nft.approve(bob, 0);

        vm.prank(bob);
        nft.transferFrom(alice, bob, 0);

        assertEq(nft.ownerOf(0), bob);
        assertEq(rev.lastUpdated(), bob);
    }

    /*//////////////////////////////////////////////////////////////
                   Helpers to mock AddressManager responses
    //////////////////////////////////////////////////////////////*/

    function _mockAddressManagerReturn(address mockManager, address revModule) internal {
        // inject minimal bytecode so it's a contract
        vm.etch(mockManager, hex"60006000");

        bytes memory selector = abi.encodeWithSelector(
            IAddressManager.getProtocolAddressByName.selector,
            "REVENUE_SHARE_MODULE"
        );

        ProtocolAddress memory response = ProtocolAddress({
            name: keccak256("REVENUE_SHARE_MODULE"),
            addr: revModule,
            addressType: ProtocolAddressType.Protocol
        });

        vm.mockCall(mockManager, selector, abi.encode(response));
    }

    function _mockAddressManagerRevert(address mockManager) internal {
        vm.etch(mockManager, hex"60006000");
        bytes memory selector = abi.encodeWithSelector(
            IAddressManager.getProtocolAddressByName.selector,
            "REVENUE_SHARE_MODULE"
        );
        vm.mockCallRevert(mockManager, selector, "Mock failure");
    }

    /*//////////////////////////////////////////////////////////////
                                UPGRADES
    //////////////////////////////////////////////////////////////*/

    function testNft_upgrade() public {
        address newImpl = address(new RevShareNFT());

        vm.prank(nft.owner());
        nft.upgradeToAndCall(newImpl, "");
    }
}
