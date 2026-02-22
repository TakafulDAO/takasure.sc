// SPDX-License-Identifier: GNU GPLv3

/**
 * @title ISFUSDCMintUSDC
 * @author Maikel Ordaz
 * @notice Minimal interface for the legacy Arbitrum Sepolia SFUSDC token.
 * @notice Inbound-only CCIP pool for legacy SFUSDC that mints via `mintUSDC(address,uint256)`.
 * @dev Intended for Arbitrum Sepolia where the existing token cannot be changed.
 */

pragma solidity 0.8.24;

import {ITypeAndVersion} from "ccip/contracts/src/v0.8/shared/interfaces/ITypeAndVersion.sol";
import {Pool} from "ccip/contracts/src/v0.8/ccip/libraries/Pool.sol";
import {TokenPool} from "ccip/contracts/src/v0.8/ccip/pools/TokenPool.sol";
import {IERC20} from "ccip/contracts/src/v0.8/vendor/openzeppelin-solidity/v4.8.3/contracts/token/ERC20/IERC20.sol";

interface ISFUSDCMintUSDC {
    function mintUSDC(address to, uint256 amount) external;
}

contract SFUSDCMintUSDCOnlyPool is TokenPool, ITypeAndVersion {
    string public constant override typeAndVersion = "SFUSDCMintUSDCOnlyPool 1.0.0";

    error SFUSDCMintUSDCOnlyPool__OutboundDisabled();

    constructor(address token, uint8 localTokenDecimals, address[] memory allowlist, address rmnProxy, address router)
        TokenPool(IERC20(token), localTokenDecimals, allowlist, rmnProxy, router)
    {}

    /// @notice Outbound transfers are intentionally disabled because Arbitrum Sepolia is receiver-only in this setup.
    function lockOrBurn(Pool.LockOrBurnInV1 calldata) external pure override returns (Pool.LockOrBurnOutV1 memory) {
        revert SFUSDCMintUSDCOnlyPool__OutboundDisabled();
    }

    /// @notice Mints legacy SFUSDC on destination via `mintUSDC`.
    function releaseOrMint(Pool.ReleaseOrMintInV1 calldata releaseOrMintIn)
        external
        override
        returns (Pool.ReleaseOrMintOutV1 memory)
    {
        _validateReleaseOrMint(releaseOrMintIn);

        uint256 localAmount =
            _calculateLocalAmount(releaseOrMintIn.amount, _parseRemoteDecimals(releaseOrMintIn.sourcePoolData));

        ISFUSDCMintUSDC(address(i_token)).mintUSDC(releaseOrMintIn.receiver, localAmount);

        emit Minted(msg.sender, releaseOrMintIn.receiver, localAmount);

        return Pool.ReleaseOrMintOutV1({destinationAmount: localAmount});
    }
}
