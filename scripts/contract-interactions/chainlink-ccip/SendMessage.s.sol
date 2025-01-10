// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {Sender} from "contracts/chainlink/ccip/Sender.sol";
import {CcipHelperConfig} from "deploy/utils/configs/CcipHelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SendMessage is Script, GetContractAddress {
    function run() public {
        uint256 chainId = block.chainid;
        uint256 amountToApprove = 1e6; // 1 USDC

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(
            chainId
        );

        address senderAddress = _getContractAddress(chainId, "Sender");
        Sender sender = Sender(payable(senderAddress));

        IERC20 usdc = IERC20(config.usdc);

        vm.startBroadcast();

        usdc.approve(address(sender), amountToApprove);
        sender.transferUSDCPayLINK(amountToApprove);

        vm.stopBroadcast();
    }
}
