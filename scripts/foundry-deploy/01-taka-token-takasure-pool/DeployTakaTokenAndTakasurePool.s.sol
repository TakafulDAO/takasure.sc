// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";
import {TakaToken} from "../../../contracts/token/TakaToken.sol";
import {TakasurePool} from "../../../contracts/token/TakasurePool.sol";
import {HelperConfig} from "../HelperConfig.s.sol";

contract DeployTakaTokenAndTakasurePool is Script {
    address defaultAdmin = makeAddr("defaultAdmin");

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run() external returns (TakaToken, TakasurePool, HelperConfig) {
        HelperConfig config = new HelperConfig();

        (, , , uint256 deployerKey) = config.activeNetworkConfig();

        vm.startBroadcast(deployerKey);

        TakaToken takaToken = new TakaToken();
        TakasurePool takasurePool = new TakasurePool(address(takaToken));

        takaToken.grantRole(MINTER_ROLE, address(takasurePool));
        takaToken.grantRole(BURNER_ROLE, address(takasurePool));

        vm.stopBroadcast();

        return (takaToken, takasurePool, config);
    }
}
