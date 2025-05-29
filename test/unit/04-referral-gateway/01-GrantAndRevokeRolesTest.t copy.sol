// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";

contract ReferralGatewayGrantAndRevokeRolesTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    address referralGatewayAddress;
    address takadao;
    address KYCProvider;
    address pauseGuardian;

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (, , , referralGatewayAddress, , , , , , , helperConfig) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        KYCProvider = config.kycProvider;
        pauseGuardian = config.pauseGuardian;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
    }

    function testRoles() public {
        // Addresses that will be used to test the roles
        address newOperator = makeAddr("newOperator");
        address newKYCProvider = makeAddr("newKYCProvider");
        // New addresses without roles
        assert(!referralGateway.hasRole(keccak256("OPERATOR"), newOperator));
        assert(!referralGateway.hasRole(keccak256("KYC_PROVIDER"), newKYCProvider));
        // Grant, revoke and renounce roles
        vm.startPrank(takadao);
        referralGateway.grantRole(keccak256("OPERATOR"), newOperator);
        referralGateway.grantRole(keccak256("KYC_PROVIDER"), newKYCProvider);
        referralGateway.revokeRole(keccak256("OPERATOR"), takadao);
        referralGateway.revokeRole(keccak256("KYC_PROVIDER"), KYCProvider);
        vm.stopPrank();
        // New addresses with roles
        assert(referralGateway.hasRole(keccak256("OPERATOR"), newOperator));
        assert(referralGateway.hasRole(keccak256("KYC_PROVIDER"), newKYCProvider));
        // Old addresses without roles
        assert(!referralGateway.hasRole(keccak256("OPERATOR"), takadao));
        assert(!referralGateway.hasRole(keccak256("KYC_PROVIDER"), KYCProvider));
    }

    function testAdminRoles() public {
        // Address that will be used to test the roles
        address newAdmin = makeAddr("newAdmin");
        address newCouponRedeemer = makeAddr("newCouponRedeemer");

        bytes32 defaultAdminRole = 0x00;
        bytes32 couponRedeemerRole = keccak256("COUPON_REDEEMER");

        // Current address with roles
        assert(referralGateway.hasRole(defaultAdminRole, takadao));

        // New addresses without roles
        assert(!referralGateway.hasRole(defaultAdminRole, newAdmin));

        // Current Admin can give and remove anyone a role
        vm.prank(takadao);
        referralGateway.grantRole(couponRedeemerRole, newCouponRedeemer);

        assert(referralGateway.hasRole(couponRedeemerRole, newCouponRedeemer));

        vm.prank(takadao);
        referralGateway.revokeRole(couponRedeemerRole, newCouponRedeemer);

        assert(!referralGateway.hasRole(couponRedeemerRole, newCouponRedeemer));

        // Grant, revoke and renounce roles
        vm.startPrank(takadao);
        referralGateway.grantRole(defaultAdminRole, newAdmin);
        referralGateway.renounceRole(defaultAdminRole, takadao);
        vm.stopPrank();

        // New addresses with roles
        assert(referralGateway.hasRole(defaultAdminRole, newAdmin));

        // Old addresses without roles
        assert(!referralGateway.hasRole(defaultAdminRole, takadao));

        // New Admin can give and remove anyone a role
        vm.prank(newAdmin);
        referralGateway.grantRole(couponRedeemerRole, newCouponRedeemer);

        assert(referralGateway.hasRole(couponRedeemerRole, newCouponRedeemer));

        vm.prank(newAdmin);
        referralGateway.revokeRole(couponRedeemerRole, newCouponRedeemer);

        assert(!referralGateway.hasRole(couponRedeemerRole, newCouponRedeemer));

        // Old Admin can no longer give anyone a role
        vm.prank(takadao);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                takadao,
                defaultAdminRole
            )
        );
        referralGateway.grantRole(couponRedeemerRole, newCouponRedeemer);
    }
}
