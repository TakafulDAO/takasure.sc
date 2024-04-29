// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {TakaToken} from "../../contracts/token/TakaToken.sol";
import {TakasurePool} from "../../contracts/takasure/TakasurePool.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployTokenAndPool is Script {
    address defaultAdmin = makeAddr("defaultAdmin");

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run()
        external
        returns (
            TakaToken,
            ERC1967Proxy,
            TakasurePool,
            address contributionTokenAddress,
            HelperConfig
        )
    {
        HelperConfig config = new HelperConfig();

        (
            address contributionToken,
            uint256 deployerKey,
            address wakalaClaimAddress,
            address daoOperator
        ) = config.activeNetworkConfig();

        vm.startBroadcast(deployerKey);

        TakaToken takaToken = new TakaToken();
        TakasurePool takasurePool = new TakasurePool();
        ERC1967Proxy proxy = new ERC1967Proxy(address(takasurePool), "");

        TakasurePool(address(proxy)).initialize(
            contributionToken,
            address(takaToken),
            wakalaClaimAddress,
            daoOperator
        );

        takaToken.grantRole(MINTER_ROLE, address(proxy));
        takaToken.grantRole(BURNER_ROLE, address(proxy));

        vm.stopBroadcast();

        contributionTokenAddress = TakasurePool(address(proxy)).getContributionTokenAddress();

        return (takaToken, proxy, takasurePool, contributionTokenAddress, config);
    }
}
