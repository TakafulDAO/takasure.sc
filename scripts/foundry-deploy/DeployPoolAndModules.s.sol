// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

import {Script} from "forge-std/Script.sol";
import {TakasurePool} from "../../contracts/token/TakasurePool.sol";
import {MembersModule} from "../../contracts/modules/MembersModule.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployPoolAndModules is Script {
    address defaultAdmin = makeAddr("defaultAdmin");

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    function run()
        external
        returns (
            TakasurePool,
            ERC1967Proxy,
            MembersModule,
            address contributionTokenAddress,
            HelperConfig
        )
    {
        HelperConfig config = new HelperConfig();

        (address contributionToken, uint256 deployerKey) = config.activeNetworkConfig();

        vm.startBroadcast(deployerKey);

        TakasurePool takasurePool = new TakasurePool();
        MembersModule membersModule = new MembersModule();
        ERC1967Proxy proxy = new ERC1967Proxy(address(membersModule), "");

        MembersModule(address(proxy)).initialize(contributionToken, address(takasurePool));

        takasurePool.grantRole(MINTER_ROLE, address(proxy));
        takasurePool.grantRole(BURNER_ROLE, address(proxy));

        vm.stopBroadcast();

        contributionTokenAddress = MembersModule(address(proxy)).getContributionTokenAddress();

        return (takasurePool, proxy, membersModule, contributionTokenAddress, config);
    }
}
