// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";

contract ChangeOperator is Script, GetContractAddress {
    IERC20 public usdc;
    HelperConfig public helperConfig;

    address public safeMultiSig = 0x0259F914D29006510177B620e828a3eD93D762cf;

    function run() public {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        address referralGatewayAddress = _getContractAddress(block.chainid, "ReferralGateway");

        ReferralGateway referralGateway = ReferralGateway(referralGatewayAddress);
        usdc = IERC20(config.contributionToken);

        vm.startBroadcast();

        usdc.approve(referralGatewayAddress, usdc.balanceOf(msg.sender));

        referralGateway.setNewOperator({newOperator: safeMultiSig});

        vm.stopBroadcast();
    }
}
