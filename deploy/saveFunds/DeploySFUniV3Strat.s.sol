// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFUniswapV3Strategy} from "contracts/saveFunds/SFUniswapV3Strategy.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

contract DeploySFUniV3Strat is Script, GetContractAddress {
    address constant SFUSDC_ADDRESS_ARBITRUM_SEPOLIA = 0x2fE9378AF2f1aeB8b013031d1a3567F6E0d44dA1;
    address constant SFUSDT_ADDRESS_ARBITRUM_SEPOLIA = 0x27a59b95553BE7D51103E772A713f0A15d447356;
    address constant POOL_ARB_SEPOLIA = 0x51dff4A270295C78CA668c3B6a8b427269AeaA7f; // USDC/USDT 0.05% fee
    address constant POSITION_MANAGER = 0x6b2937Bde17889EDCf8fbD8dE31C3C2a70Bc4d65;
    address constant ROUTER = 0x4A7b5Da61326A6379179b40d00F57E5bbDC962c2;

    function run() external returns (address proxy) {
        // uint256 chainId = block.chainid;
        // HelperConfig helperConfig = new HelperConfig();
        // HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(chainId);

        IAddressManager addressManager = IAddressManager(_getContractAddress(block.chainid, "AddressManager"));
        address vault = _getContractAddress(block.chainid, "SFVault");
        address math = _getContractAddress(block.chainid, "UniswapV3MathHelper");

        vm.startBroadcast();

        // Deploy SFUniswapV3Strategy
        // todo: update for mainnnet deployment
        proxy = Upgrades.deployUUPSProxy(
            "SFUniswapV3Strategy.sol",
            abi.encodeCall(
                SFUniswapV3Strategy.initialize,
                (
                    addressManager,
                    vault,
                    IERC20(SFUSDC_ADDRESS_ARBITRUM_SEPOLIA),
                    IERC20(SFUSDT_ADDRESS_ARBITRUM_SEPOLIA),
                    POOL_ARB_SEPOLIA,
                    POSITION_MANAGER,
                    math,
                    0,
                    ROUTER,
                    -600,
                    600
                )
            )
        );

        vm.stopBroadcast();

        return (proxy);
    }
}
