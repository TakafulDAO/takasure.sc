// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";
import {SFUSDCCcipTestnet} from "deploy/ccip/testnetPool/neededContracts/SFUSDCCcipTestnet.sol";

/// @notice Deploys a CCIP-compatible SFUSDC replacement token on Arbitrum Sepolia.
/// @dev Keeps the same symbol/name ("SFUSDC") and permissionless mintUSDC for team testing.
contract DeploySFUSDCCcipTestnetArbSepolia is Script, DeployConstants {
    error DeploySFUSDCCcipTestnetArbSepolia__UnsupportedChainId(uint256 chainId);

    address internal constant OWNER = 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1;
    bytes32 internal constant SALT = "SFUSDC_CCIP_TESTNET_V1";

    function run() external returns (SFUSDCCcipTestnet token_) {
        uint256 chainId = block.chainid;
        if (chainId != ARB_SEPOLIA_CHAIN_ID) {
            revert DeploySFUSDCCcipTestnetArbSepolia__UnsupportedChainId(chainId);
        }

        vm.startBroadcast();
        token_ = new SFUSDCCcipTestnet{salt: SALT}(OWNER);
        vm.stopBroadcast();
    }
}
