// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployReferralGateway} from "test/utils/TestDeployReferralGateway.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";

contract ReferralGatewayTest is Test {
    TestDeployReferralGateway deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    address proxy;
    address takadao;

    function setUp() public {
        deployer = new TestDeployReferralGateway();
        (, proxy, helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        takadao = config.takadaoOperator;

        referralGateway = ReferralGateway(address(proxy));
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/
    function testSetIsPreJoinEnabled() public {
        assert(referralGateway.isPreJoinEnabled());

        vm.prank(referralGateway.owner());
        referralGateway.setPreJoinEnabled(false);

        assert(!referralGateway.isPreJoinEnabled());
    }

    /*//////////////////////////////////////////////////////////////
                                REVERTS
    //////////////////////////////////////////////////////////////*/
}
