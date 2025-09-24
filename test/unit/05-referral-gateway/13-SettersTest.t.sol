// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract ReferralGatewaySettersTests is Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address referralGatewayAddress;
    address operator;
    address couponUser = makeAddr("couponUser");
    address couponPool = makeAddr("couponPool");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "TheLifeDAO";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee

    event OnNewCouponPoolAddress(address indexed oldCouponPool, address indexed newCouponPool);
    event OnCouponRedeemed(
        address indexed member,
        string indexed tDAOName,
        uint256 indexed couponAmount
    );

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (, referralGatewayAddress, , , , , , , usdcAddress, , helperConfig) = deployer.run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        operator = config.takadaoOperator;

        // Assign implementations
        referralGateway = ReferralGateway(address(referralGatewayAddress));
        usdc = IUSDC(usdcAddress);

        // Give and approve USDC

        // To the coupon user, he must pay part of the contribution
        deal(address(usdc), couponUser, USDC_INITIAL_AMOUNT);
        vm.prank(couponUser);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);

        // To the coupon pool, it will be used to pay the coupon
        deal(address(usdc), couponPool, 1000e6);
        vm.prank(couponPool);
        usdc.approve(address(referralGateway), 1000e6);

        vm.prank(config.daoMultisig);
        referralGateway.createDAO(true, true, 1743479999, 1e12);
    }

    function testSetNewCouponPoolAddress() public {
        vm.prank(operator);
        vm.expectEmit(true, true, false, false, address(referralGateway));
        emit OnNewCouponPoolAddress(address(0), couponPool);
        referralGateway.setCouponPoolAddress(couponPool);
    }
}
