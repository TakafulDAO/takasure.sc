// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {TokenTransferSource} from "contracts/chainlink/ccip/TokenTransferSource.sol";
import {DevOpsTools} from "foundry-devops/src/DevOpsTools.sol";
import {CcipHelperConfig} from "deploy/CcipHelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TransferUsdcPayWithLink is Script {
    function run() public {
        uint256 chainId = block.chainid;
        uint256 amountToApprove = 1e6; // 1 USDC

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(
            chainId
        );

        address tokenTransferSourceAddress = DevOpsTools.get_most_recent_deployment(
            "TokenTransferSource",
            chainId
        );
        TokenTransferSource tokenTransferSource = TokenTransferSource(
            payable(tokenTransferSourceAddress)
        );

        IERC20 usdc = IERC20(config.usdc);

        vm.startBroadcast();

        usdc.approve(address(tokenTransferSource), amountToApprove);
        tokenTransferSource.transferUSDCPayLINK(amountToApprove);

        vm.stopBroadcast();
    }
}
