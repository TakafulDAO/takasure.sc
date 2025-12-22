// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {ProtocolAddressType} from "contracts/types/Managers.sol";

contract AddAddresses is Script, GetContractAddress {
    address constant RECIPIENT = 0x3904F59DF9199e0d6dC3800af9f6794c9D037eb1;

    function run() public {
        address addressManagerAddress = _getContractAddress(block.chainid, "AddressManager");
        address vault = _getContractAddress(block.chainid, "SFVault");
        address aggregator = _getContractAddress(block.chainid, "SFStrategyAggregator");
        AddressManager addressManager = AddressManager(addressManagerAddress);

        vm.startBroadcast();

        addressManager.addProtocolAddress("PROTOCOL__SF_VAULT", vault, ProtocolAddressType.Protocol);
        addressManager.addProtocolAddress("PROTOCOL__SF_AGGREGATOR", aggregator, ProtocolAddressType.Protocol);
        addressManager.addProtocolAddress("SF_VAULT_FEE_RECIPIENT", RECIPIENT, ProtocolAddressType.Admin);

        vm.stopBroadcast();
    }
}
