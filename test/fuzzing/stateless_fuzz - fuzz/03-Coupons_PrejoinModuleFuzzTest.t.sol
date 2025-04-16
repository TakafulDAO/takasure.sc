// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";

contract CouponCodeAndCcipFuzzTest is Test {
    TestDeployProtocol deployer;
    PrejoinModule prejoinModule;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address prejoinModuleAddress;
    address operator;
    address couponUser = makeAddr("couponUser");
    address ccipUser = makeAddr("ccipUser");
    address couponPool = makeAddr("couponPool");
    address ccipReceiverContract = makeAddr("ccipReceiverContract");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "TheLifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee

    event OnNewCouponPoolAddress(address indexed oldCouponPool, address indexed newCouponPool);
    event OnCouponRedeemed(address indexed member, uint256 indexed couponAmount);
    event OnNewCCIPReceiverContract(
        address indexed oldCCIPReceiverContract,
        address indexed newCCIPReceiverContract
    );

    function setUp() public {
        // Deployer
        deployer = new TestDeployProtocol();
        // Deploy contracts
        (, bmConsumerMock, , prejoinModuleAddress, , , , , usdcAddress, , helperConfig) = deployer
            .run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        operator = config.takadaoOperator;

        // Assign implementations
        prejoinModule = PrejoinModule(address(prejoinModuleAddress));
        usdc = IUSDC(usdcAddress);

        // Give and approve USDC

        // To the coupon user, he must pay part of the contribution
        deal(address(usdc), couponUser, USDC_INITIAL_AMOUNT);
        vm.prank(couponUser);
        usdc.approve(address(prejoinModule), USDC_INITIAL_AMOUNT);

        // To the coupon pool, it will be used to pay the coupon
        deal(address(usdc), couponPool, 1000e6);
        vm.prank(couponPool);
        usdc.approve(address(prejoinModule), 1000e6);

        // To the ccip receiver contract, it will be used to pay the contributions of the ccip user
        deal(address(usdc), ccipReceiverContract, 1000e6);
        vm.prank(ccipReceiverContract);
        usdc.approve(address(prejoinModule), 1000e6);

        vm.startPrank(config.daoMultisig);
        prejoinModule.createDAO(true, true, 1743479999, 1e12, address(bmConsumerMock));
        vm.stopPrank();

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(prejoinModuleAddress);

        vm.startPrank(operator);
        prejoinModule.setCouponPoolAddress(couponPool);
        prejoinModule.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        prejoinModule.setCCIPReceiverContract(ccipReceiverContract);
        vm.stopPrank();
    }

    // Fuzz to test to check the caller can only be the coupon redeemer or the ccip receiver contract
    function testPayContributionOnBehalfOfRevertsIfCallerIsWrong(address caller) public {
        vm.assume(caller != couponRedeemer);
        vm.assume(caller != ccipReceiverContract);

        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        vm.prank(caller);
        vm.expectRevert(PrejoinModule.PrejoinModule__NotAuthorizedCaller.selector);
        prejoinModule.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            address(0),
            couponUser,
            couponAmount
        );
    }
}
