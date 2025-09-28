// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {RevShareNFT} from "contracts/tokens/RevShareNFT.sol";
import {RevShareModuleMock} from "test/mocks/RevShareModuleMock.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {ProtocolAddress, ProtocolAddressType} from "contracts/types/TakasureTypes.sol";

contract RevShareNftHandler is Test {
    RevShareNFT public nft;
    address[] public users;
    uint256 public maxUsers = 10;

    constructor(RevShareNFT _nft) {
        nft = _nft;

        for (uint256 i = 0; i < maxUsers; i++) {
            address user = address(uint160(uint256(keccak256(abi.encode("user", i)))));
            users.push(user);
        }
    }

    function mint(uint256 index) external {
        address to = users[index % users.length];
        try nft.mint(to) {} catch {}
    }

    function batchMint(uint256 index, uint256 amount) external {
        address to = users[index % users.length];
        if (amount <= 1 || amount > 20) return; // skip invalid
        try nft.batchMint(to, amount) {} catch {}
    }

    function transfer(uint256 fromIdx, uint256 toIdx, uint256 tokenId) external {
        address from = users[fromIdx % users.length];
        address to = users[toIdx % users.length];

        vm.prank(from);
        try nft.approve(to, tokenId) {} catch {}

        vm.prank(to);
        try nft.transferFrom(from, to, tokenId) {} catch {}
    }

    function setAddressManager() external {
        RevShareModuleMock rev = new RevShareModuleMock();
        address mockManager = address(0xABAB);

        // Inject AddressManager mock
        vm.etch(mockManager, hex"60006000");
        bytes memory selector = abi.encodeWithSelector(
            IAddressManager.getProtocolAddressByName.selector,
            "REVENUE_SHARE_MODULE"
        );

        ProtocolAddress memory response = ProtocolAddress({
            name: keccak256("REVENUE_SHARE_MODULE"),
            addr: address(rev),
            addressType: ProtocolAddressType.Protocol
        });

        vm.mockCall(mockManager, selector, abi.encode(response));

        vm.prank(nft.owner());
        nft.setAddressManager(mockManager);
    }

    function usersLength() external view returns (uint256) {
        return users.length;
    }

    // To avoid this contract to be count in coverage
    function test() external {}
}
