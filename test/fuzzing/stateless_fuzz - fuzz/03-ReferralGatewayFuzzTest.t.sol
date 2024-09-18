// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.25;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployReferralGateway} from "test/utils/TestDeployReferralGateway.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";

contract ReferralGatewayFuzzTest is Test {
    TestDeployReferralGateway deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    address proxy;
    address takadao;

    function setUp() public {
        deployer = new TestDeployReferralGateway();
        (, proxy, , helperConfig) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);

        takadao = config.takadaoOperator;

        referralGateway = ReferralGateway(address(proxy));
    }

    function test_fuzz_onlyOwnerCanEnablePreJoin(address notOwner) public {
        // The input address must not be the same as the takasurePool address
        vm.assume(notOwner != takadao);

        vm.prank(notOwner);
        vm.expectRevert();
        referralGateway.setPreJoinEnabled(false);
    }

    function test_fuzz_onlyOwnerCanApproveAsAmbassador(
        address notOwner,
        address ambassador
    ) public {
        // The input address must not be the same as the takasurePool address
        vm.assume(notOwner != takadao);
        vm.assume(ambassador != takadao);
        vm.assume(ambassador != notOwner);
        vm.assume(ambassador != address(0));

        vm.prank(notOwner);
        vm.expectRevert();
        referralGateway.approveAsAmbassador(ambassador);
    }
}
