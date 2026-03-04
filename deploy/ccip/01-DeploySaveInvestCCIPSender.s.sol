// SPDX-License-Identifier: GNU GPLv3

/// @notice Run in Avax (Mainnet and Fuji), Base (Mainnet and Sepolia), Ethereum (Mainnet and Sepolia),
///         Optimism (Mainnet and Sepolia), Polygon (Mainnet and Amoy)

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SaveInvestCCIPSender} from "contracts/helpers/chainlink/ccip/SaveInvestCCIPSender.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";

contract DeploySaveInvestCCIPSender is Script, DeployConstants, GetContractAddress {
    uint256 private constant DEFAULT_MAX_GAS_LIMIT = 1_200_000;
    string private constant DEFAULT_PROTOCOL_NAME = "PROTOCOL__SF_VAULT";

    function run() external returns (address) {
        uint256 chainId = block.chainid;

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(chainId);

        address receiverContractAddress;
        address tokenToBridge;
        uint64 destinationChainSelector;
        bytes32 salt = "222025";
        bool isTestNet = chainId == AVAX_FUJI_CHAIN_ID || chainId == BASE_SEPOLIA_CHAIN_ID
            || chainId == ETH_SEPOLIA_CHAIN_ID || chainId == OP_SEPOLIA_CHAIN_ID || chainId == POL_AMOY_CHAIN_ID;

        if (isTestNet) {
            receiverContractAddress = _getContractAddress(ARB_SEPOLIA_CHAIN_ID, "SaveInvestCCIPReceiver");
            destinationChainSelector = ARB_SEPOLIA_SELECTOR;
            tokenToBridge = _getContractAddress(chainId, "SFUSDCCcipTestnet");
        } else {
            receiverContractAddress = _getContractAddress(ARB_MAINNET_CHAIN_ID, "SaveInvestCCIPReceiver");
            destinationChainSelector = ARB_MAINNET_SELECTOR;
            tokenToBridge = config.usdc;
        }

        require(config.senderOwner != address(0), "Invalid senderOwner");

        vm.startBroadcast();
        (, address caller,) = vm.readCallers();
        console2.log("SaveInvestCCIPSender owner to initialize:");
        console2.logAddress(caller);

        // Deploy implementation
        SaveInvestCCIPSender senderContract = new SaveInvestCCIPSender();

        // Deploy proxy
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(address(senderContract), "");

        SaveInvestCCIPSender(address(proxy))
            .initialize(
                config.router,
                config.link,
                tokenToBridge,
                receiverContractAddress,
                destinationChainSelector,
                caller
            );

        // Make sender ready to use before ownership handoff.
        SaveInvestCCIPSender(address(proxy)).setMaxGasLimit(DEFAULT_MAX_GAS_LIMIT);
        SaveInvestCCIPSender(address(proxy)).setSupportedProtocol(DEFAULT_PROTOCOL_NAME, true);

        if (caller != config.senderOwner) {
            SaveInvestCCIPSender(address(proxy)).transferOwnership(config.senderOwner);
        }

        vm.stopBroadcast();

        console2.log("SaveInvestCCIPSender deployed at:");
        console2.logAddress(address(proxy));
        console2.log("maxGasLimit configured:");
        console2.logUint(DEFAULT_MAX_GAS_LIMIT);
        console2.log("supported protocol enabled:");
        console2.log(DEFAULT_PROTOCOL_NAME);
        console2.log("owner initialized as:");
        console2.logAddress(caller);
        console2.log("pending owner configured as:");
        console2.logAddress(config.senderOwner);

        return address(proxy);
    }
}
