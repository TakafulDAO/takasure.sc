// SPDX-License-Identifier: GPL-3.0-only

/**
 * @title PositionReader
 * @author Maikel Ordaz
 * @notice Library for reading positions from the NonfungiblePositionManager avoiding stack too deep errors.
 */
pragma solidity 0.8.28;

import {INonfungiblePositionManager} from "contracts/interfaces/helpers/INonfungiblePositionManager.sol";

library PositionReader {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint256 internal constant WORDS = 12;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/
    error PositionReader__StaticcallFailed();
    error PositionReader__UnexpectedReturnLength();
    error PositionReader__IdxOutOfBounds();

    function _rawWord(INonfungiblePositionManager _pm, uint256 _tokenId, uint256 _idx)
        internal
        view
        returns (bytes32 w_)
    {
        require(_idx < WORDS, PositionReader__IdxOutOfBounds());

        (bool _ok, bytes memory _ret) =
            address(_pm).staticcall(abi.encodeWithSelector(_pm.positions.selector, _tokenId));

        require(_ok, PositionReader__StaticcallFailed());
        require(_ret.length >= 32 * WORDS, PositionReader__UnexpectedReturnLength());

        // first word at ret + 0x20; pick word #idx (0-based)
        assembly {
            w_ := mload(add(_ret, add(0x20, mul(_idx, 0x20))))
        }
    }

    function _getUint24(INonfungiblePositionManager _pm, uint256 _tokenId, uint256 _idx)
        internal
        view
        returns (uint24)
    {
        return uint24(uint256(_rawWord(_pm, _tokenId, _idx)));
    }

    function _getUint96(INonfungiblePositionManager _pm, uint256 _tokenId, uint256 _idx)
        internal
        view
        returns (uint96)
    {
        return uint96(uint256(_rawWord(_pm, _tokenId, _idx)));
    }

    function _getUint128(INonfungiblePositionManager _pm, uint256 _tokenId, uint256 _idx)
        internal
        view
        returns (uint128)
    {
        return uint128(uint256(_rawWord(_pm, _tokenId, _idx)));
    }

    function _getUint256(INonfungiblePositionManager _pm, uint256 _tokenId, uint256 _idx)
        internal
        view
        returns (uint256)
    {
        return uint256(_rawWord(_pm, _tokenId, _idx));
    }

    function _getAddress(INonfungiblePositionManager _pm, uint256 _tokenId, uint256 _idx)
        internal
        view
        returns (address)
    {
        return address(uint160(uint256(_rawWord(_pm, _tokenId, _idx))));
    }

    function _getInt24(INonfungiblePositionManager _pm, uint256 _tokenId, uint256 _idx) internal view returns (int24) {
        // go bytes32 -> uint256 (bits) -> int256 (two's complement) -> int24 (truncate)
        return int24(int256(uint256(_rawWord(_pm, _tokenId, _idx))));
    }
}
