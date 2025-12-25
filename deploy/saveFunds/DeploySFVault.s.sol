// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

contract DeploySFVault is Script, GetContractAddress {
    address constant SFUSDC_ADDRESS_ARBITRUM_SEPOLIA = 0x2fE9378AF2f1aeB8b013031d1a3567F6E0d44dA1;
    address constant SFUSDT_ADDRESS_ARBITRUM_SEPOLIA = 0x27a59b95553BE7D51103E772A713f0A15d447356;

    function run() external returns (address proxy) {
        uint256 chainId = block.chainid;
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(chainId);

        IAddressManager addressManager = IAddressManager(_getContractAddress(block.chainid, "AddressManager"));

        vm.startBroadcast();

        // Deploy SFVault
        // todo: update for mainnnet deployment
        proxy = Upgrades.deployUUPSProxy(
            "SFVault.sol",
            abi.encodeCall(
                SFVault.initialize, (addressManager, IERC20(SFUSDC_ADDRESS_ARBITRUM_SEPOLIA), "SF Vault", "SFV")
            )
        );

        SFVault(proxy).whitelistToken(SFUSDT_ADDRESS_ARBITRUM_SEPOLIA);

        vm.stopBroadcast();

        return (proxy);
    }
}
