// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {stdJson} from "forge-std/Script.sol";
import {DeploymentArtifacts} from "deploy/utils/DeploymentArtifacts.s.sol";

contract WriteDeploymentJsons is DeploymentArtifacts {
    using stdJson for string;

    function run() external {
        string memory inputPath = string.concat(_deploymentsDir(block.chainid), "/deployments.input.json");
        string memory json = vm.readFile(inputPath);
        string[] memory names = json.readStringArray(".names");
        address[] memory addrs = json.readAddressArray(".addresses");

        require(names.length == addrs.length, "Mismatched arrays");
        require(names.length > 0, "No deployments provided");

        DeploymentItem[] memory items = new DeploymentItem[](names.length);
        for (uint256 i; i < names.length; ++i) {
            items[i] = DeploymentItem({name: names[i], addr: addrs[i]});
        }

        _writeDeployments(block.chainid, items);
    }
}
