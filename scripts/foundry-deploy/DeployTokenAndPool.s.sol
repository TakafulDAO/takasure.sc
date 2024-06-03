// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Script, console2} from "forge-std/Script.sol";
import {TheLifeDAOToken} from "../../contracts/token/TheLifeDAOToken.sol";
import {TakasurePool} from "../../contracts/takasure/TakasurePool.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployTokenAndPool is Script {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run()
        external
        returns (
            TheLifeDAOToken,
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

        address deployerAddress = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        TheLifeDAOToken tldToken = new TheLifeDAOToken();
        TakasurePool takasurePool = new TakasurePool();
        ERC1967Proxy proxy = new ERC1967Proxy(address(takasurePool), "");

        TakasurePool(address(proxy)).initialize(
            contributionToken,
            address(tldToken),
            wakalaClaimAddress,
            daoOperator
        );

        tldToken.grantRole(MINTER_ROLE, address(proxy));
        tldToken.grantRole(BURNER_ROLE, address(proxy));

        bytes32 adminRole = tldToken.DEFAULT_ADMIN_ROLE();
        tldToken.grantRole(adminRole, daoOperator);

        tldToken.revokeRole(adminRole, deployerAddress);

        vm.stopBroadcast();

        contributionTokenAddress = TakasurePool(address(proxy)).getContributionTokenAddress();

        return (tldToken, proxy, takasurePool, contributionTokenAddress, config);
    }
}
