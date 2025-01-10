// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Receiver} from "contracts/chainlink/ccip/Receiver.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";

contract DeployReceiver is Script {
    uint256 public constant ARB_SEPOLIA_CHAIN_ID = 421614;
    uint256 public constant AVAX_FUJI_CHAIN_ID = 43113;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;
    uint256 public constant ETH_SEPOLIA_CHAIN_ID = 11155111;
    uint256 public constant OP_SEPOLIA_CHAIN_ID = 11155420;
    uint256 public constant POL_AMOY_CHAIN_ID = 80002;

    address public constant REFERRAL_MAINNET = 0x14Eb9897c6b7Ac579e6eFE130287e2729b9A018E;
    address public constant REFERRAL_TESTNET = 0x303892f65aD2862b496fd946E3827E71fcF88e47;

    uint64 public constant ARB_ONE_CHAIN_SELECTOR = 4949039107694359620;
    uint64 public constant ARB_SEPOLIA_CHAIN_SELECTOR = 3478487238524512106;

    function run() external returns (Receiver) {
        uint256 chainId = block.chainid;

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(
            block.chainid
        );

        address referralContract;
        bytes32 salt = "1960";

        if (
            chainId == ARB_SEPOLIA_CHAIN_ID ||
            chainId == AVAX_FUJI_CHAIN_ID ||
            chainId == BASE_SEPOLIA_CHAIN_ID ||
            chainId == ETH_SEPOLIA_CHAIN_ID ||
            chainId == OP_SEPOLIA_CHAIN_ID ||
            chainId == POL_AMOY_CHAIN_ID
        ) {
            referralContract = REFERRAL_TESTNET;
        } else {
            referralContract = REFERRAL_MAINNET;
        }

        vm.startBroadcast();

        // Deploy Receiver contract
        Receiver receiver = new Receiver{salt: salt}(config.router, config.usdc, referralContract);

        vm.stopBroadcast();

        return (receiver);
    }
}
