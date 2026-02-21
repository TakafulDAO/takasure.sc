// SPDX-License-Identifier: GNU GPLv3

/// @notice Run only in Arbitrum (One and Sepolia)

pragma solidity 0.8.28;

import {Script, console2, stdJson, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {SFAndIFCcipReceiver} from "contracts/helpers/chainlink/SFAndIFCcipReceiver.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract DeploySFAndIFReceiver is Script, DeployConstants, GetContractAddress {
    function run() external returns (SFAndIFCcipReceiver) {
        uint256 chainId = block.chainid;

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(block.chainid);

        IAddressManager addressManager = IAddressManager(_getContractAddress(chainId, "AddressManager"));

        vm.startBroadcast();

        // Deploy SFAndIFCcipReceiver contract
        SFAndIFCcipReceiver receiver = new SFAndIFCcipReceiver(addressManager, config.router, config.usdc);

        vm.stopBroadcast();

        return (receiver);
    }
}
