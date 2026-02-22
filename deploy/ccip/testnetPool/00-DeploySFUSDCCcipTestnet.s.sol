// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";
import {SFUSDCCcipTestnet} from "deploy/ccip/testnetPool/neededContracts/SFUSDCCcipTestnet.sol";

/// @notice Deploy testnet-only SFUSDC token with CCIP burn/mint compatibility.
contract DeploySFUSDCCcipTestnet is Script, DeployConstants {
    error DeploySFUSDCCcipTestnet__UnsupportedChainId(uint256 chainId);
    address constant OWNER = 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1;

    function run() external returns (SFUSDCCcipTestnet token_) {
        uint256 chainId = block.chainid;
        bytes32 salt = "SFUSDC_CCIP_TESTNET_V1";
        if (!_isSupportedTestnet(chainId)) {
            revert DeploySFUSDCCcipTestnet__UnsupportedChainId(chainId);
        }

        vm.startBroadcast();
        token_ = new SFUSDCCcipTestnet{salt: salt}(OWNER);
        vm.stopBroadcast();
    }

    function _isSupportedTestnet(uint256 chainId) internal pure returns (bool) {
        return chainId == AVAX_FUJI_CHAIN_ID || chainId == BASE_SEPOLIA_CHAIN_ID || chainId == ETH_SEPOLIA_CHAIN_ID
            || chainId == OP_SEPOLIA_CHAIN_ID || chainId == POL_AMOY_CHAIN_ID;
    }
}
