// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFStrategyAggregator} from "contracts/saveFunds/SFStrategyAggregator.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

contract DeploySFStrategyAggregator is Script, GetContractAddress {
    address constant SFUSDC_ADDRESS_ARBITRUM_SEPOLIA = 0x2fE9378AF2f1aeB8b013031d1a3567F6E0d44dA1;

    function run() external returns (address proxy) {
        // uint256 chainId = block.chainid;
        // HelperConfig helperConfig = new HelperConfig();
        // HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(chainId);

        IAddressManager addressManager = IAddressManager(_getContractAddress(block.chainid, "AddressManager"));
        // address vault = _getContractAddress(block.chainid, "SFVault");

        vm.startBroadcast();

        // Deploy SFStrategyAggregator
        // todo: update for mainnnet deployment
        proxy = Upgrades.deployUUPSProxy(
            "SFStrategyAggregator.sol",
            abi.encodeCall(SFStrategyAggregator.initialize, (addressManager, IERC20(SFUSDC_ADDRESS_ARBITRUM_SEPOLIA)))
        );

        vm.stopBroadcast();

        return (proxy);
    }
}
