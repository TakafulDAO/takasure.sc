// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {EntryModule} from "contracts/modules/EntryModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract RolesPrejoinModuleTest is Test {
    TestDeployProtocol deployer;
    PrejoinModule prejoinModule;
    TakasureReserve takasureReserve;
    EntryModule entryModule;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address prejoinModuleAddress;
    address takasureReserveAddress;
    address entryModuleAddress;
    address takadao;
    address daoAdmin;
    address KYCProvider;
    address referral = makeAddr("referral");
    address member = makeAddr("member");
    address notMember = makeAddr("notMember");
    address child = makeAddr("child");
    string tDaoName = "TheLifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (
            ,
            bmConsumerMock,
            takasureReserveAddress,
            prejoinModuleAddress,
            entryModuleAddress,
            ,
            ,
            ,
            usdcAddress,
            ,
            helperConfig
        ) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        daoAdmin = config.daoMultisig;
        KYCProvider = config.kycProvider;

        // Assign implementations
        prejoinModule = PrejoinModule(prejoinModuleAddress);
        takasureReserve = TakasureReserve(takasureReserveAddress);
        entryModule = EntryModule(entryModuleAddress);
        usdc = IUSDC(usdcAddress);

        // Config mocks
        vm.startPrank(daoAdmin);
        takasureReserve.setNewContributionToken(address(usdc));
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));
        takasureReserve.setNewPrejoinModule(address(prejoinModule));
        vm.stopPrank();

        vm.startPrank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(address(takasureReserve));
        bmConsumerMock.setNewRequester(prejoinModuleAddress);
        vm.stopPrank();

        // Give and approve USDC
        deal(address(usdc), referral, USDC_INITIAL_AMOUNT);
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        deal(address(usdc), member, USDC_INITIAL_AMOUNT);

        vm.prank(referral);
        usdc.approve(address(prejoinModule), USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(prejoinModule), USDC_INITIAL_AMOUNT);
        vm.prank(member);
        usdc.approve(address(takasureReserve), USDC_INITIAL_AMOUNT);
    }

    modifier createDao() {
        vm.startPrank(daoAdmin);
        prejoinModule.createDAO(tDaoName, true, true, 1743479999, 1e12, address(bmConsumerMock));
        prejoinModule.setDAOName(tDaoName);
        vm.stopPrank();
        _;
    }

    modifier referralPrepays() {
        vm.prank(referral);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, address(0));
        _;
    }

    modifier KYCReferral() {
        vm.prank(KYCProvider);
        prejoinModule.setKYCStatus(referral);
        _;
    }

    modifier referredPrepays() {
        vm.prank(child);
        prejoinModule.payContribution(CONTRIBUTION_AMOUNT, referral);

        _;
    }

    function testRoles() public createDao referralPrepays KYCReferral referredPrepays {
        // Addresses that will be used to test the roles
        address newOperator = makeAddr("newOperator");
        address newKYCProvider = makeAddr("newKYCProvider");
        // Current addresses with roles
        assert(prejoinModule.hasRole(keccak256("OPERATOR"), takadao));
        assert(prejoinModule.hasRole(keccak256("KYC_PROVIDER"), KYCProvider));
        // New addresses without roles
        assert(!prejoinModule.hasRole(keccak256("OPERATOR"), newOperator));
        assert(!prejoinModule.hasRole(keccak256("KYC_PROVIDER"), newKYCProvider));
        // Current KYCProvider can KYC a member
        vm.prank(KYCProvider);
        prejoinModule.setKYCStatus(child);
        // Grant, revoke and renounce roles
        vm.startPrank(takadao);
        prejoinModule.grantRole(keccak256("OPERATOR"), newOperator);
        prejoinModule.grantRole(keccak256("KYC_PROVIDER"), newKYCProvider);
        prejoinModule.revokeRole(keccak256("OPERATOR"), takadao);
        prejoinModule.revokeRole(keccak256("KYC_PROVIDER"), KYCProvider);
        vm.stopPrank();
        // New addresses with roles
        assert(prejoinModule.hasRole(keccak256("OPERATOR"), newOperator));
        assert(prejoinModule.hasRole(keccak256("KYC_PROVIDER"), newKYCProvider));
        // Old addresses without roles
        assert(!prejoinModule.hasRole(keccak256("OPERATOR"), takadao));
        assert(!prejoinModule.hasRole(keccak256("KYC_PROVIDER"), KYCProvider));
    }

    function testAdminRole() public createDao referralPrepays KYCReferral referredPrepays {
        // Address that will be used to test the roles
        address newAdmin = makeAddr("newAdmin");
        address newCouponRedeemer = makeAddr("newCouponRedeemer");

        bytes32 defaultAdminRole = 0x00;
        bytes32 couponRedeemer = keccak256("COUPON_REDEEMER");

        // Current address with roles
        assert(prejoinModule.hasRole(defaultAdminRole, takadao));

        // New addresses without roles
        assert(!prejoinModule.hasRole(defaultAdminRole, newAdmin));

        // Current Admin can give and remove anyone a role
        vm.prank(takadao);
        prejoinModule.grantRole(couponRedeemer, newCouponRedeemer);

        assert(prejoinModule.hasRole(couponRedeemer, newCouponRedeemer));

        vm.prank(takadao);
        prejoinModule.revokeRole(couponRedeemer, newCouponRedeemer);

        assert(!prejoinModule.hasRole(couponRedeemer, newCouponRedeemer));

        // Grant, revoke and renounce roles
        vm.startPrank(takadao);
        prejoinModule.grantRole(defaultAdminRole, newAdmin);
        prejoinModule.renounceRole(defaultAdminRole, takadao);
        vm.stopPrank();

        // New addresses with roles
        assert(prejoinModule.hasRole(defaultAdminRole, newAdmin));

        // Old addresses without roles
        assert(!prejoinModule.hasRole(defaultAdminRole, takadao));

        // New Admin can give and remove anyone a role
        vm.prank(newAdmin);
        prejoinModule.grantRole(couponRedeemer, newCouponRedeemer);

        assert(prejoinModule.hasRole(couponRedeemer, newCouponRedeemer));

        vm.prank(newAdmin);
        prejoinModule.revokeRole(couponRedeemer, newCouponRedeemer);

        assert(!prejoinModule.hasRole(couponRedeemer, newCouponRedeemer));

        // Old Admin can no longer give anyone a role
        vm.prank(takadao);
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)",
                takadao,
                defaultAdminRole
            )
        );
        prejoinModule.grantRole(couponRedeemer, newCouponRedeemer);
    }
}
