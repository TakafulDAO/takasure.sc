// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";

contract ChangeAdmin is Script, GetContractAddress {
    function run() public {
        address referralGatewayAddress = _getContractAddress(block.chainid, "ReferralGateway");

        ReferralGateway referralGateway = ReferralGateway(referralGatewayAddress);

        address safeMultiSig = vm.envAddress("MULTISIG_ADDRESS"); // ! CHANGE THIS

        vm.startBroadcast();

        referralGateway.grantRole({role: 0x00, account: safeMultiSig});
        referralGateway.renounceRole({role: 0x00, callerConfirmation: msg.sender});

        vm.stopBroadcast();
    }
}
