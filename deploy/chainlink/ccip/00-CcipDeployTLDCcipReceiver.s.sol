// SPDX-License-Identifier: GNU GPLv3

/// @notice Run only in Arbitrum (One and Sepolia)

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TLDCcipReceiver} from "contracts/chainlink/ccip/TLDCcipReceiver.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract DeployTLDCcipReceiver is Script, DeployConstants, GetContractAddress {
    function run() external returns (TLDCcipReceiver) {
        uint256 chainId = block.chainid;

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(
            block.chainid
        );

        address referralContractAddress = _getContractAddress(chainId, "ReferralGateway");

        vm.startBroadcast();

        // Deploy TLDCcipReceiver contract
        TLDCcipReceiver receiver = new TLDCcipReceiver(
            config.router,
            config.usdc,
            referralContractAddress
        );

        vm.stopBroadcast();

        return (receiver);
    }
}
