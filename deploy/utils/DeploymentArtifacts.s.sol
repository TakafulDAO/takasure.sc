// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {DeployConstants} from "deploy/utils/DeployConstants.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ProtocolAddressType, ProposedRoleHolder} from "contracts/types/Managers.sol";

abstract contract DeploymentArtifacts is Script, DeployConstants {
    struct DeploymentItem {
        string name;
        address addr;
    }

    struct ProtocolAddressRow {
        string name;
        address addr;
        ProtocolAddressType addrType;
    }

    function _chainName(uint256 chainId) internal pure returns (string memory) {
        if (chainId == ARB_MAINNET_CHAIN_ID) return "mainnet_arbitrum_one";
        if (chainId == ARB_SEPOLIA_CHAIN_ID) return "testnet_arbitrum_sepolia";
        if (chainId == ETH_SEPOLIA_CHAIN_ID) return "testnet_ethereum_sepolia";
        if (chainId == LOCAL_CHAIN_ID) return "local";
        revert("Unsupported chainId");
    }

    function _deploymentsDir(uint256 chainId) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/deployments/", _chainName(chainId));
    }

    function _artifactPath(string memory contractName) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), "/out/", contractName, ".sol/", contractName, ".json");
    }

    function _writeDeploymentJson(uint256 chainId, string memory contractName, address addr) internal {
        string memory dir = _deploymentsDir(chainId);
        vm.createDir(dir, true);

        string memory artifact = vm.readFile(_artifactPath(contractName));
        string memory abiJson = _extractAbiJson(artifact);
        string memory json = string.concat(
            "{\"address\":\"",
            vm.toString(addr),
            "\",\"abi\":",
            abiJson,
            "}"
        );

        string memory outPath = string.concat(dir, "/", contractName, ".json");
        vm.writeJson(json, outPath);
    }

    function _writeDeployments(uint256 chainId, DeploymentItem[] memory items) internal {
        for (uint256 i; i < items.length; ++i) {
            _writeDeploymentJson(chainId, items[i].name, items[i].addr);
        }
    }

    function _writeAddressManagerCsv(
        uint256 chainId,
        AddressManager addressManager,
        ProtocolAddressRow[] memory protocolAddresses,
        string memory fileName
    ) internal {
        string memory dir = _deploymentsDir(chainId);
        vm.createDir(dir, true);
        string memory outPath = string.concat(dir, "/", fileName);

        string memory csv = "section,role,proposedHolder,currentHolder,addressName,address,addressType\n";

        bytes32[] memory roles = addressManager.getRoles();
        for (uint256 i; i < roles.length; ++i) {
            bytes32 role = roles[i];
            address currentHolder = addressManager.currentRoleHolders(role);
            ProposedRoleHolder memory proposed = addressManager.getProposedRoleHolder(role);

            csv = string.concat(
                csv,
                "role,",
                vm.toString(role),
                ",",
                vm.toString(proposed.proposedHolder),
                ",",
                vm.toString(currentHolder),
                ",,,\n"
            );
        }

        for (uint256 i; i < protocolAddresses.length; ++i) {
            ProtocolAddressRow memory row = protocolAddresses[i];
            csv = string.concat(
                csv,
                "address,,,",
                row.name,
                ",",
                vm.toString(row.addr),
                ",",
                _protocolAddressTypeToString(row.addrType),
                "\n"
            );
        }

        vm.writeFile(outPath, csv);
    }

    function _protocolAddressTypeToString(ProtocolAddressType addrType) internal pure returns (string memory) {
        if (addrType == ProtocolAddressType.Admin) return "Admin";
        if (addrType == ProtocolAddressType.Benefit) return "Benefit";
        if (addrType == ProtocolAddressType.Module) return "Module";
        if (addrType == ProtocolAddressType.Protocol) return "Protocol";
        if (addrType == ProtocolAddressType.External) return "External";
        if (addrType == ProtocolAddressType.Helper) return "Helper";
        return "Unknown";
    }

    function _extractAbiJson(string memory artifact) internal pure returns (string memory) {
        bytes memory data = bytes(artifact);
        bytes memory needle = bytes("\"abi\":");
        uint256 keyIndex = _findSubstring(data, needle);
        require(keyIndex != type(uint256).max, "ABI key not found");

        uint256 start = _findChar(data, 0x5b, keyIndex + needle.length); // '['
        require(start != type(uint256).max, "ABI array start not found");

        uint256 end = _findMatchingBracket(data, start);
        uint256 len = end - start + 1;
        bytes memory abiBytes = new bytes(len);
        for (uint256 i; i < len; ++i) {
            abiBytes[i] = data[start + i];
        }
        return string(abiBytes);
    }

    function _findSubstring(bytes memory data, bytes memory needle) internal pure returns (uint256) {
        if (needle.length == 0 || data.length < needle.length) return type(uint256).max;
        for (uint256 i; i <= data.length - needle.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < needle.length; ++j) {
                if (data[i + j] != needle[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return i;
        }
        return type(uint256).max;
    }

    function _findChar(bytes memory data, bytes1 needle, uint256 start) internal pure returns (uint256) {
        for (uint256 i = start; i < data.length; ++i) {
            if (data[i] == needle) return i;
        }
        return type(uint256).max;
    }

    function _findMatchingBracket(bytes memory data, uint256 start) internal pure returns (uint256) {
        bytes1 quote = 0x22; // '"'
        bytes1 escape = 0x5c; // '\\'
        bytes1 lbracket = 0x5b; // '['
        bytes1 rbracket = 0x5d; // ']'

        bool inString = false;
        bool isEscaped = false;
        uint256 depth = 0;

        for (uint256 i = start; i < data.length; ++i) {
            bytes1 c = data[i];
            if (inString) {
                if (isEscaped) {
                    isEscaped = false;
                    continue;
                }
                if (c == escape) {
                    isEscaped = true;
                } else if (c == quote) {
                    inString = false;
                }
                continue;
            }

            if (c == quote) {
                inString = true;
                continue;
            }

            if (c == lbracket) {
                depth++;
            } else if (c == rbracket) {
                if (depth == 0) revert("ABI array end not found");
                depth--;
                if (depth == 0) return i;
            }
        }

        revert("ABI array end not found");
    }
}
