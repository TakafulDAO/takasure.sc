// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {ProtocolAddress, ProtocolAddressType} from "contracts/types/Managers.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {RevShareModuleMock} from "test/mocks/RevShareModuleMock.sol";

contract RevShareNftTest is Test {
    RevShareNFT nft;
    address operator = makeAddr("operator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    event OnAddressManagerSet(address indexed oldAddressManager, address indexed newAddressManager);
    event OnBaseURISet(string indexed oldBaseUri, string indexed newBaseURI);
    event OnPeriodTransferLockSet(uint256 indexed newPeriod);
    event OnRevShareNFTMinted(address indexed owner, uint256 tokenId);
    event OnBatchRevShareNFTMinted(address indexed newOwner, uint256 initialTokenId, uint256 lastTokenId);

    function setUp() public {
        string memory baseURI = "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/";
        address nftImplementation = address(new RevShareNFT());
        address nftAddress = UnsafeUpgrades.deployUUPSProxy(
            nftImplementation, abi.encodeCall(RevShareNFT.initialize, (baseURI, msg.sender))
        );
        nft = RevShareNFT(nftAddress);
    }

    /*//////////////////////////////////////////////////////////////
                                  INIT
    //////////////////////////////////////////////////////////////*/

    function testNft_initialValues() public view {
        assertEq(nft.MAX_SUPPLY(), 8_820);
        assertEq(nft.totalSupply(), 0);
        assertEq(nft.baseURI(), "https://ipfs.io/ipfs/QmQUeGU84fQFknCwATGrexVV39jeVsayGJsuFvqctuav6p/");
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

        assertEq(nft.tokenURI(0), "https://ipfs.io/ipfs/Qmb2yMfCt7zqCP5C2aoMAeYh9qyfabSTcb7URzV85zfZME/0.json");
    }

    function testNft_tokenURIEmptyWhenBaseURINotSet() public {
        address impl = address(new RevShareNFT());
        RevShareNFT noBaseUri =
            RevShareNFT(UnsafeUpgrades.deployUUPSProxy(impl, abi.encodeCall(RevShareNFT.initialize, ("", msg.sender))));

        vm.prank(noBaseUri.owner());
        noBaseUri.mint(alice);

        assertEq(noBaseUri.tokenURI(0), "");
    }

    function testNft_setPeriodTransferLock() public {
        vm.prank(nft.owner());
        vm.expectEmit(true, false, false, false, address(nft));
        emit OnPeriodTransferLockSet(1 weeks);
        nft.setPeriodTransferLock(1 weeks);
    }

    function testNft_periodChangeAppliesRetroactively() public {
        vm.startPrank(nft.owner());
        nft.setPeriodTransferLock(2 weeks);
        nft.mint(alice);
        vm.stopPrank();

        // After 10 days (still < 2 weeks), reduce lock to 1 week
        vm.warp(block.timestamp + 10 days);

        vm.prank(nft.owner());
        nft.setPeriodTransferLock(1 weeks);

        // Now transfer should pass
        vm.prank(alice);
        nft.transfer(bob, 0);
        assertEq(nft.ownerOf(0), bob);
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

    function testNft_sentinelFirstMintIsMinimum() public {
        vm.prank(nft.owner());
        nft.setPeriodTransferLock(30 days);

        vm.prank(nft.owner());
        nft.mint(alice);
        uint256 first = nft.pioneerMintedAt(alice, type(uint256).max);

        // Advance time and mint again
        vm.warp(block.timestamp + 10 days);
        vm.prank(nft.owner());
        nft.mint(alice);

        // Sentinel should remain the earlier timestamp (min)
        uint256 sentinel = nft.pioneerMintedAt(alice, type(uint256).max);
        assertEq(sentinel, first);
    }

    function testNft_mintRevertsWhenMintingToThisContract() public {
        vm.prank(nft.owner());
        vm.expectRevert(RevShareNFT.RevShareNFT__NotAllowedAddress.selector);
        nft.mint(address(nft));
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
                               APPROVALS
    //////////////////////////////////////////////////////////////*/

    function testNft_approveRevokeAllowedDuringLock() public {
        // lock = 1 week
        vm.prank(nft.owner());
        nft.setPeriodTransferLock(1 weeks);

        // mint to alice
        vm.prank(nft.owner());
        nft.mint(alice);

        // During lock, granting should revert…
        vm.prank(alice);
        vm.expectRevert(RevShareNFT.RevShareNFT__TooEarlyToTransfer.selector);
        nft.approve(bob, 0);

        // …but revoking (approve to zero) must be allowed
        vm.prank(alice);
        nft.approve(address(0), 0);
    }

    function testNFT_setApprovalForAllRevokeAllowedDuringLock() public {
        vm.prank(nft.owner());
        nft.setPeriodTransferLock(1 weeks);

        // Mint so OWNER_LOCK_KEY is set for alice
        vm.prank(nft.owner());
        nft.mint(alice);

        // During lock, enabling should revert…
        vm.prank(alice);
        vm.expectRevert(RevShareNFT.RevShareNFT__TooEarlyToTransfer.selector);
        nft.setApprovalForAll(bob, true);

        // …but disabling is allowed
        vm.prank(alice);
        nft.setApprovalForAll(bob, false);
    }

    function test_approveGrantAllowedAfterLock() public {
        vm.prank(nft.owner());
        nft.setPeriodTransferLock(1 weeks);

        vm.prank(nft.owner());
        nft.mint(alice);

        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        nft.approve(bob, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               TRANSFERS
    //////////////////////////////////////////////////////////////*/

    modifier transferLockSetup() {
        vm.prank(nft.owner());
        nft.setPeriodTransferLock(1 weeks);
        _;
    }

    function testNft_safeTransferFromRevertsDuringLock_ThenSucceeds() public transferLockSetup {
        vm.prank(nft.owner());
        nft.mint(alice);

        // During lock -> revert
        vm.prank(alice);
        vm.expectRevert(RevShareNFT.RevShareNFT__TooEarlyToTransfer.selector);
        nft.safeTransferFrom(alice, bob, 0);

        // After lock -> success
        vm.warp(block.timestamp + 8 days);
        vm.prank(alice);
        nft.safeTransferFrom(alice, bob, 0);
        assertEq(nft.ownerOf(0), bob);
    }

    function testNft_transferFromRevertsWhenMintedAtNotSet() public {
        // Mint to alice so token 0 exists and has mintedAt under alice
        vm.prank(nft.owner());
        nft.mint(alice);

        // bob tries to transfer "from bob" -> mintedAt[bob][0] == 0 => revert
        vm.prank(bob);
        vm.expectRevert(RevShareNFT.RevShareNFT__MintedAtNotSet.selector);
        nft.transferFrom(bob, alice, 0);
    }

    function testNft_transferRevertsIfIsTooEarlyToTransfer() public transferLockSetup {
        vm.prank(nft.owner());
        nft.mint(alice);

        vm.prank(alice);
        vm.expectRevert(RevShareNFT.RevShareNFT__TooEarlyToTransfer.selector);
        nft.transfer(bob, 0);
    }

    function testNft_transferFromRevertsIfIsTooEarlyTooTransfer() public transferLockSetup {
        vm.prank(nft.owner());
        nft.mint(alice);

        // vm.warp(block.timestamp + 1 weeks);
        // vm.roll(block.number + 1);

        vm.prank(alice);
        vm.expectRevert(RevShareNFT.RevShareNFT__TooEarlyToTransfer.selector);
        nft.approve(bob, 0);

        // vm.prank(bob);
        // vm.expectRevert(RevShareNFT.RevShareNFT__TooEarlyToTransfer.selector);
        // nft.transferFrom(alice, bob, 0);
    }

    function testNft_transferWorksIfLockPeriodHasPassed() public transferLockSetup {
        vm.prank(nft.owner());
        nft.mint(alice);

        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 1);

        vm.prank(alice);
        nft.transfer(bob, 0);

        assertEq(nft.ownerOf(0), bob);
    }

    function testNft_transferFromWorksIfLockPeriodHasPassed() public transferLockSetup {
        vm.prank(nft.owner());
        nft.mint(alice);

        vm.warp(block.timestamp + 1 weeks);
        vm.roll(block.number + 1);

        vm.prank(alice);
        nft.approve(bob, 0);

        vm.prank(bob);
        nft.transferFrom(alice, bob, 0);

        assertEq(nft.ownerOf(0), bob);
    }

    /*//////////////////////////////////////////////////////////////
                   Helpers to mock AddressManager responses
    //////////////////////////////////////////////////////////////*/

    function _mockAddressManagerReturn(address mockManager, address revModule) internal {
        // inject minimal bytecode so it's a contract
        vm.etch(mockManager, hex"60006000");

        bytes memory selector =
            abi.encodeWithSelector(IAddressManager.getProtocolAddressByName.selector, "REVENUE_SHARE_MODULE");

        ProtocolAddress memory response = ProtocolAddress({
            name: keccak256("REVENUE_SHARE_MODULE"), addr: revModule, addressType: ProtocolAddressType.Protocol
        });

        vm.mockCall(mockManager, selector, abi.encode(response));
    }

    function _mockAddressManagerRevert(address mockManager) internal {
        vm.etch(mockManager, hex"60006000");
        bytes memory selector =
            abi.encodeWithSelector(IAddressManager.getProtocolAddressByName.selector, "REVENUE_SHARE_MODULE");
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

    /*//////////////////////////////////////////////////////////////
                               MIGRATION
    //////////////////////////////////////////////////////////////*/

    function testNft_migrationRevertsWhenRangeExceedsSupply() public {
        // no tokens minted => totalSupply = 0
        vm.prank(nft.owner());
        vm.expectRevert(bytes("range exceeds supply"));
        nft.migrateOwnerFirstMintForRange(0, 1);
    }

    function testNft_migrationSetsOwnerLockMinOverTokens() public {
        // Mint three tokens with different timestamps
        vm.startPrank(nft.owner());
        nft.mint(alice); // id 0
        vm.warp(block.timestamp + 5);
        nft.mint(alice); // id 1
        vm.warp(block.timestamp + 5);
        nft.mint(alice); // id 2
        vm.stopPrank();

        // Wipe sentinel to simulate pre-upgrade holders
        // (We can't alter storage directly here, so just clear by migrating a subset first that won't set it)
        // Now migrate over [0,3)
        vm.prank(nft.owner());
        nft.migrateOwnerFirstMintForRange(0, 3);

        // Sentinel must equal the earliest (id 0) timestamp
        uint256 ts0 = nft.pioneerMintedAt(alice, 0);
        uint256 sentinel = nft.pioneerMintedAt(alice, type(uint256).max);
        assertEq(sentinel, ts0);
    }
}
