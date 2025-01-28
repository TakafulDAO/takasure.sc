// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TLDCcipSender} from "contracts/chainlink/ccip/TLDCcipSender.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";

contract AddSupportedToken is Script, GetContractAddress {
    function run() public {
        uint256 chainId = block.chainid;

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();
        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(
            chainId
        );

        address senderAddress = _getContractAddress(chainId, "TLDCcipSender");

        TLDCcipSender sender = TLDCcipSender(payable(senderAddress));

        vm.startBroadcast();

        sender.addSupportedToken({token: config.usdc});

        vm.stopBroadcast();
    }
}
