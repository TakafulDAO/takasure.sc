// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployReferralGateway} from "test/utils/00-DeployReferralGateway.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayInitializationTest is Test {
    DeployReferralGateway deployer;
    ReferralGateway referralGateway;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takadao;
    address KYCProvider;
    address pauseGuardian;
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDAO";

    function setUp() public {
        deployer = new DeployReferralGateway();
        HelperConfig.NetworkConfig memory config;
        (config, referralGateway) = deployer.run();

        // Get config values
        takadao = config.takadaoOperator;
        KYCProvider = config.kycProvider;
        pauseGuardian = config.pauseGuardian;

        // Assign implementations
        usdc = IUSDC(config.contributionToken);
    }

    function testOperatorAddressIsNotZero() public view {
        uint256 operatorAddressSlot = 2;
        bytes32 operatorAddressSlotBytes = vm.load(
            address(referralGateway),
            bytes32(uint256(operatorAddressSlot))
        );
        address operatorAddress = address(uint160(uint256(operatorAddressSlotBytes)));
        assert(operatorAddress != address(0));
    }

    function testUsdcAddressIsNotZero() public view {
        console2.log("USDC Address:", address(referralGateway.usdc()));
        assert(address(referralGateway.usdc()) != address(0));
        assertEq(address(referralGateway.usdc()), address(usdc));
    }

    function testDAONameAssignCorrectly() public view {
        string memory name = referralGateway.daoName();
        assertEq(name, "The LifeDAO");
    }

    function testOperatorRoleAssignedCorrectly() public view {
        assert(referralGateway.hasRole(keccak256("OPERATOR"), takadao));
    }

    function testKYCRoleAssignedCorrectly() public view {
        assert(referralGateway.hasRole(keccak256("KYC_PROVIDER"), KYCProvider));
    }

    function testPauseGuardianRoleAssignedCorrectly() public view {
        assert(referralGateway.hasRole(keccak256("PAUSE_GUARDIAN"), pauseGuardian));
    }
}
