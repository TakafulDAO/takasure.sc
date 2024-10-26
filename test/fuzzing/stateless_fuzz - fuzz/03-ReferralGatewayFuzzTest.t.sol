// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";

contract ReferralGatewayFuzzTest is Test {
    TestDeployTakasure deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    address proxy;
    address takadao;

    function setUp() public {
        deployer = new TestDeployTakasure();
        (, , , proxy, , , helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        takadao = config.takadaoOperator;

        referralGateway = ReferralGateway(address(proxy));
    }
}
