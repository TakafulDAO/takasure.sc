// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {SFVault} from "contracts/saveFunds/SFVault.sol";

contract InvestIntoStrategy is Script, GetContractAddress {
    struct V3ActionData {
        uint16 otherRatioBPS; // 0..10000 (default 5000)
        bytes swapToOtherData; // abi.encode(bytes[] inputs, uint256 deadline) for underlying->otherToken
        bytes swapToUnderlyingData; // abi.encode(bytes[] inputs, uint256 deadline) for otherToken->underlying
        uint256 pmDeadline; // deadline for positionManager mint/increase/decrease
        uint256 minUnderlying; // slippage floor for underlying side in mint/increase/decrease
        uint256 minOther; // slippage floor for otherToken side in mint/increase/decrease
    }

    function run() public {
        address uniV3Strat = _getContractAddress(block.chainid, "SFUniswapV3Strategy");
        address vault = _getContractAddress(block.chainid, "SFVault");
        address sfUSDC = _getContractAddress(block.chainid, "SFUSDC");
        address sfUSDT = _getContractAddress(block.chainid, "SFUSDT");

        uint256 assets = 1000e6;
        uint16 otherRatioBPS = 5_000;
        uint256 amountToSwap = (assets * otherRatioBPS) / 10_000;

        bytes memory path = abi.encodePacked(sfUSDC, uint24(500), sfUSDT);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(uniV3Strat, amountToSwap, 0, path, true);

        uint256 deadline = block.timestamp + 600;

        bytes memory swapToOtherData = abi.encode(inputs, deadline);

        bytes memory v3ActionData = abi.encode(otherRatioBPS, swapToOtherData, bytes(""), deadline, 0, 0);

        address[] memory strategies = new address[](1);
        strategies[0] = uniV3Strat;

        bytes[] memory payloads = new bytes[](1);
        payloads[0] = v3ActionData;

        vm.startBroadcast();
        SFVault(vault).investIntoStrategy(assets, strategies, payloads);
        vm.stopBroadcast();
    }
}
