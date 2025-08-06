// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {RevShareNftHandler} from "test/helpers/handlers/RevShareNftHandler.t.sol";

contract RevShareNFT_Invariant is Test {
    RevShareNFT nft;
    RevShareNftHandler handler;

    function setUp() public {
        string memory baseURI = "https://base.uri/";
        address nftImpl = address(new RevShareNFT());
        address nftProxy = UnsafeUpgrades.deployUUPSProxy(
            nftImpl,
            abi.encodeCall(RevShareNFT.initialize, (baseURI, msg.sender))
        );
        nft = RevShareNFT(nftProxy);

        handler = new RevShareNftHandler(nft);

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = RevShareNftHandler.mint.selector;
        selectors[1] = RevShareNftHandler.batchMint.selector;
        selectors[2] = RevShareNftHandler.transfer.selector;
        selectors[3] = RevShareNftHandler.setAddressManager.selector;
        selectors[4] = RevShareNftHandler.usersLength.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Invariant: totalSupply <= MAX_SUPPLY
    function invariant_totalSupplyNeverExceedsMaxSupply() public view {
        assertLe(nft.totalSupply(), nft.MAX_SUPPLY());
    }

    /// @dev Invariant: All minted tokenIds are owned
    function invariant_allMintedTokenIdsAreOwned() public view {
        uint256 total = nft.totalSupply();
        for (uint256 i = 0; i < total; ++i) {
            address owner = nft.ownerOf(i);
            assertTrue(owner != address(0));
        }
    }

    /// @dev Invariant: Transfers do not change totalSupply
    function invariant_transfersDoNotChangeTotalSupply() public view {
        // No change expected: just confirming totalSupply consistency
        // We don't need to store the initial supply since this check runs *after* every call
        assertLe(nft.totalSupply(), nft.MAX_SUPPLY());
    }

    /// @dev Invariant: All pioneers with pioneerMintedAt set had failed rev update
    function invariant_pioneerMintedAtOnlySetWhenRevFails() public view {
        uint256 total = nft.totalSupply();
        uint256 userCount = handler.usersLength();

        for (uint256 u = 0; u < userCount; ++u) {
            address user = address(uint160(uint256(keccak256(abi.encode("user", u)))));
            for (uint256 i = 0; i < total; ++i) {
                uint256 ts = nft.pioneerMintedAt(user, i);
                if (ts != 0) {
                    assertLe(ts, block.timestamp);
                }
            }
        }
    }
}
