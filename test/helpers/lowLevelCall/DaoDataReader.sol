// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

interface IReferralGateway {
    function getDAOData()
        external
        view
        returns (
            bool,
            bool,
            bool,
            address,
            address,
            uint256,
            uint256,
            uint256,
            uint256,
            address,
            uint256, // index 10 -> toRepool
            uint256
        );
}

library DaoDataReader {
    function _rawWord(IReferralGateway g, uint256 idx) internal view returns (bytes32 w) {
        // there should be exactly 12 * 32 = 384 bytes of return data
        (bool ok, bytes memory ret) = address(g).staticcall(
            abi.encodeWithSelector(IReferralGateway.getDAOData.selector)
        );
        require(ok, "getDAOData() staticcall failed");
        require(ret.length >= 32 * 12, "unexpected return length");
        // first word is at ret + 0x20; pick word #idx (0-based)
        assembly {
            w := mload(add(ret, add(0x20, mul(idx, 0x20))))
        }
    }

    function getUint(IReferralGateway g, uint256 idx) internal view returns (uint256) {
        return uint256(_rawWord(g, idx));
    }
    function getAddress(IReferralGateway g, uint256 idx) internal view returns (address) {
        return address(uint160(uint256(_rawWord(g, idx))));
    }
    function getBool(IReferralGateway g, uint256 idx) internal view returns (bool) {
        return uint256(_rawWord(g, idx)) != 0;
    }
}
