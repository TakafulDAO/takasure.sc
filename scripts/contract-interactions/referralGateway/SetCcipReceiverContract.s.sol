// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";

contract SetCcipReceiverContract is Script, GetContractAddress {
    function run() public {
        address referralGatewayAddress = _getContractAddress(block.chainid, "ReferralGateway");
        address ccipReceiverContractAddress = _getContractAddress(block.chainid, "TLDCcipReceiver");

        ReferralGateway referralGateway = ReferralGateway(referralGatewayAddress);

        vm.startBroadcast();

        referralGateway.setCCIPReceiverContract({
            _ccipReceiverContract: ccipReceiverContractAddress
        });

        vm.stopBroadcast();
    }
}
