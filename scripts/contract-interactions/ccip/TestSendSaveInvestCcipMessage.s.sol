// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Script, console2, GetContractAddress} from "scripts/utils/GetContractAddress.s.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";
import {VmSafe} from "forge-std/Vm.sol";

interface ISFUSDCCcipTestnet {
    function mintUSDC(address to, uint256 amount) external;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface ISaveInvestCCIPSender {
    function sendMessage(string calldata protocolName, uint256 amountToTransfer, uint256 gasLimit)
        external
        returns (bytes32 messageId);
}

contract TestSendSaveInvestCcipMessage is Script, DeployConstants, GetContractAddress {
    error TestSendSaveInvestCcipMessage__UnsupportedSourceChain(uint256 chainId);
    error TestSendSaveInvestCcipMessage__InvalidAmount(uint256 amount);
    uint256 private constant TEST_AMOUNT = 200e6;
    uint256 private constant MIN_AMOUNT = 100e6;
    uint256 private constant MAX_GAS_LIMIT = 1_200_000;
    string private constant DEFAULT_PROTOCOL_NAME = "PROTOCOL__SF_VAULT";
    bytes32 private constant EMPTY_TX_HASH = bytes32(0);

    function run() external {
        uint256 chainId = block.chainid;
        _requireSupportedSourceChain(chainId);

        address senderAddr = _getContractAddress(chainId, "SaveInvestCCIPSender");
        address tokenAddr = _getContractAddress(chainId, "SFUSDCCcipTestnet");

        string memory protocolName = DEFAULT_PROTOCOL_NAME;
        uint256 amount = TEST_AMOUNT;
        uint256 gasLimit = MAX_GAS_LIMIT;

        if (amount < MIN_AMOUNT) revert TestSendSaveInvestCcipMessage__InvalidAmount(amount);

        vm.startBroadcast();
        (, address caller,) = vm.readCallers();

        console2.log("Caller:", caller);
        console2.log("Sender:", senderAddr);
        console2.log("Token:", tokenAddr);
        console2.log("Protocol:", protocolName);
        console2.log("Amount:", amount);
        console2.log("GasLimit:", gasLimit);
        console2.log("Caller token balance before:", ISFUSDCCcipTestnet(tokenAddr).balanceOf(caller));

        ISFUSDCCcipTestnet(tokenAddr).mintUSDC(caller, amount);
        ISFUSDCCcipTestnet(tokenAddr).approve(senderAddr, amount);
        bytes32 messageId = ISaveInvestCCIPSender(senderAddr).sendMessage(protocolName, amount, gasLimit);

        vm.stopBroadcast();

        (bytes32 mintTxHash, bytes32 approveTxHash) = _latestTwoTokenCallTxHashes(chainId);
        bytes32 sendTxHash = _tryLatestCallTxHash("SaveInvestCCIPSender", chainId);

        console2.log("Caller token balance after:", ISFUSDCCcipTestnet(tokenAddr).balanceOf(caller));
        console2.log("CCIP messageId:");
        console2.logBytes32(messageId);
        console2.log("mint tx hash:");
        console2.logBytes32(mintTxHash);
        console2.log("approve tx hash:");
        console2.logBytes32(approveTxHash);
        console2.log("sendMessage tx hash:");
        console2.logBytes32(sendTxHash);
        if (mintTxHash == EMPTY_TX_HASH || approveTxHash == EMPTY_TX_HASH || sendTxHash == EMPTY_TX_HASH) {
            console2.log(
                "Warning: Foundry broadcast lookup did not return all tx hashes. Use broadcast/TestSendSaveInvestCcipMessage.s.sol/<chainId>/run-latest.json"
            );
        }
    }

    function _latestTwoTokenCallTxHashes(uint256 chainId)
        internal
        view
        returns (bytes32 mintTxHash_, bytes32 approveTxHash_)
    {
        try vm.getBroadcasts("SFUSDCCcipTestnet", uint64(chainId), VmSafe.BroadcastTxType.Call) returns (
            VmSafe.BroadcastTxSummary[] memory summaries
        ) {
            if (summaries.length >= 1) approveTxHash_ = summaries[0].txHash;
            if (summaries.length >= 2) mintTxHash_ = summaries[1].txHash;
        } catch {}
    }

    function _tryLatestCallTxHash(string memory contractName, uint256 chainId) internal view returns (bytes32 txHash_) {
        try vm.getBroadcast(contractName, uint64(chainId), VmSafe.BroadcastTxType.Call) returns (
            VmSafe.BroadcastTxSummary memory summary
        ) {
            txHash_ = summary.txHash;
        } catch {
            txHash_ = EMPTY_TX_HASH;
        }
    }

    function _requireSupportedSourceChain(uint256 chainId) internal pure {
        bool isSupported =
            chainId == BASE_SEPOLIA_CHAIN_ID || chainId == ETH_SEPOLIA_CHAIN_ID || chainId == OP_SEPOLIA_CHAIN_ID;
        if (!isSupported) revert TestSendSaveInvestCcipMessage__UnsupportedSourceChain(chainId);
    }
}
