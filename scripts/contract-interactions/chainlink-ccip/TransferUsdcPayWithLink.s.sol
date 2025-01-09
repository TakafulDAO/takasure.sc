// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {TokenTransferSource} from "contracts/chainlink/ccip/TokenTransferSource.sol";
import {CcipHelperConfig} from "deploy/CcipHelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TransferUsdcPayWithLink is Script, GetContractAddress {
    function run() public {
        uint256 chainId = block.chainid;
        uint256 amountToApprove = 1e6; // 1 USDC

        CcipHelperConfig ccipHelperConfig = new CcipHelperConfig();

        CcipHelperConfig.CCIPNetworkConfig memory config = ccipHelperConfig.getConfigByChainId(
            chainId
        );

        address tokenTransferSourceAddress = _getContractAddress(chainId, "TokenTransferSource");
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
