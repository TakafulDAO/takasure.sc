// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {RevShareModuleMock} from "test/mocks/RevShareModuleMock.sol";
import {ProtocolAddress, ProtocolAddressType} from "contracts/types/TakasureTypes.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @dev Minimal ERC721 receiver to test safe mints to contracts.
contract ERC721ReceiverMock is IERC721Receiver {
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function test() external {}
}

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
            abi.encodeCall(RevShareNFT.initialize, (baseURI, msg.sender))
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

    /// @notice Happy-path fuzz: only EOAs. _safeMint to a non-receiver contract would revert by design.
    function testFuzzMintIncrementsTotalSupplyAndBalance(address to) public {
        vm.assume(to != address(0) && to != address(nft) && to.code.length == 0); // ensure EOA

        vm.startPrank(nft.owner());
        nft.mint(to);
        vm.stopPrank();

        assertEq(nft.totalSupply(), 1);
        assertEq(nft.balanceOf(to), 1);
        assertEq(nft.ownerOf(0), to);
    }

    /// @notice Batch-mint happy path: also restrict to EOAs so _safeMint cannot revert on receiver check.
    function testFuzzBatchMintValidAmounts(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != address(nft) && to.code.length == 0);
        vm.assume(amount > 1 && amount <= 100); // avoid excessive gas

        vm.startPrank(nft.owner());
        nft.batchMint(to, amount);
        vm.stopPrank();

        assertEq(nft.balanceOf(to), amount);
        assertEq(nft.totalSupply(), amount);
    }

    /// @notice Proves safe minting to a contract works when the contract implements IERC721Receiver.
    function testMintToERC721ReceiverContract() public {
        ERC721ReceiverMock receiver = new ERC721ReceiverMock();

        vm.prank(nft.owner());
        nft.mint(address(receiver));

        assertEq(nft.ownerOf(0), address(receiver), "receiver should own token 0");
        assertEq(nft.balanceOf(address(receiver)), 1);
        assertEq(nft.totalSupply(), 1);
    }

    function testFuzzTransferFromApproved(address to) public {
        vm.assume(to != address(0) && to != address(nft));
        address from = makeAddr("from");

        vm.startPrank(nft.owner());
        nft.mint(from);
        vm.stopPrank();

        vm.startPrank(from);
        nft.approve(to, 0);
        vm.stopPrank();

        address rev = address(new RevShareModuleMock());
        address manager = makeAddr("manager");
        _mockAddressManagerReturn(manager, rev);

        vm.prank(nft.owner());
        nft.setAddressManager(manager);

        vm.prank(to);
        nft.transferFrom(from, to, 0);

        assertEq(nft.ownerOf(0), to);
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
}
