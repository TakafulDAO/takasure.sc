// SPDX-License-Identifier: GNU GPLv3

/// @notice Run only in Arbitrum (One and Sepolia)

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {Receiver} from "contracts/chainlink/ccip/Receiver.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract DeployReceiver is Script, DeployConstants, GetContractAddress {
    function run() external returns (Receiver) {
        uint256 chainId = block.chainid;

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(
            block.chainid
        );

        address referralContractAddress = _getContractAddress(chainId, "ReferralGateway");

        bytes32 salt = "2020";

        vm.startBroadcast();

        // Deploy Receiver contract
        Receiver receiver = new Receiver{salt: salt}(
            config.router,
            config.usdc,
            referralContractAddress
        );

        vm.stopBroadcast();

        return (receiver);
    }
}
