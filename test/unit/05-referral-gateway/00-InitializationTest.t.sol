// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewayInitializationTest is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address takadao;
    address KYCProvider;
    address pauseGuardian;
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "The LifeDAO";

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (, referralGatewayAddress, , , , , , usdcAddress, , helperConfig) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        KYCProvider = config.kycProvider;
        pauseGuardian = config.pauseGuardian;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
        usdc = IUSDC(usdcAddress);
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
        assert(address(referralGateway.usdc()) != address(0));
        assertEq(address(referralGateway.usdc()), usdcAddress);
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
