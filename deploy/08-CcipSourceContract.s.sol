// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TokenTransferSource} from "contracts/chainlink/ccip/TokenTransferSource.sol";
import {CcipHelperConfig} from "./CcipHelperConfig.s.sol";

contract DeployTokenTransferSource is Script {
    address public constant REFERRAL_MAINNET = 0x14Eb9897c6b7Ac579e6eFE130287e2729b9A018E;
    address public constant REFERRAL_TESTNET = 0x303892f65aD2862b496fd946E3827E71fcF88e47;

    function run() external returns (TokenTransferSource) {
        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(
            block.chainid
        );

        address referralContract;

        if (block.chainid == 421614 || block.chainid == 11155111)
            referralContract = REFERRAL_TESTNET;
        else referralContract = REFERRAL_MAINNET;

        vm.startBroadcast();

        // Deploy BenefitMultiplierConsumer
        TokenTransferSource tokenTransferSource = new TokenTransferSource(
            config.router,
            config.link,
            config.usdc,
            referralContract
        );

        vm.stopBroadcast();

        return (tokenTransferSource);
    }
}
