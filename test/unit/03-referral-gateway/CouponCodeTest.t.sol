// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";
import {HelperConfig} from "deploy/HelperConfig.s.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {SimulateDonResponse} from "test/utils/SimulateDonResponse.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/src/Upgrades.sol";

contract CouponCodeTest is Test, SimulateDonResponse {
    TestDeployTakasure deployer;
    ReferralGateway referralGateway;
    TakasurePool takasurePool;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    IUSDC usdc;
    address usdcAddress;
    address proxy;
    address daoProxy;
    address takadao;
    address daoAdmin;
    address KYCProvider;
    address referral = makeAddr("referral");
    address member = makeAddr("member");
    address notMember = makeAddr("notMember");
    address child = makeAddr("child");
    address couponPool = makeAddr("couponPool");
    address couponRedeemer = makeAddr("couponRedeemer");
    string tDaoName = "TheLifeDao";
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 25e6; // 25 USDC
    uint256 public constant LAYER_ONE_REWARD_RATIO = 4; // Layer one reward ratio 4%
    uint256 public constant LAYER_TWO_REWARD_RATIO = 1; // Layer two reward ratio 1%
    uint256 public constant LAYER_THREE_REWARD_RATIO = 35; // Layer three reward ratio 0.35%
    uint256 public constant LAYER_FOUR_REWARD_RATIO = 175; // Layer four reward ratio 0.175%
    uint8 public constant SERVICE_FEE_RATIO = 27;
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution
    uint256 public constant REFERRAL_RESERVE = 5; // 5% of contribution TO Referral Reserve
    uint256 public constant REPOOL_FEE_RATIO = 2; // 2% of contribution deducted from fee

    bytes32 public constant REFERRAL = keccak256("REFERRAL");
    bytes32 private constant OPERATOR = keccak256("OPERATOR");

    struct PrepaidMember {
        string tDAOName;
        address member;
        uint256 contributionBeforeFee;
        uint256 contributionAfterFee;
        uint256 finalFee; // Fee after all the discounts and rewards
        uint256 discount;
    }

    event OnPreJoinEnabledChanged(bool indexed isPreJoinEnabled);
    event OnNewReferralProposal(address indexed proposedReferral);
    event OnNewReferral(address indexed referral);
    event OnPrepayment(
        address indexed parent,
        address indexed child,
        uint256 indexed contribution,
        uint256 fee,
        uint256 discount
    );
    event OnMemberJoined(uint256 indexed memberId, address indexed member);
    event OnNewDaoCreated(string indexed daoName);
    event OnParentRewarded(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward
    );
    event OnBenefitMultiplierConsumerChanged(
        address indexed newBenefitMultiplierConsumer,
        address indexed oldBenefitMultiplierConsumer
    );

    function setUp() public {
        // Deployer
        deployer = new TestDeployTakasure();
        // Deploy contracts
        (, bmConsumerMock, daoProxy, proxy, usdcAddress, KYCProvider, helperConfig) = deployer
            .run();

        // Get config values
        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        takadao = config.takadaoOperator;
        daoAdmin = config.daoMultisig;

        // Assign implementations
        referralGateway = ReferralGateway(address(proxy));
        takasurePool = TakasurePool(address(daoProxy));
        usdc = IUSDC(usdcAddress);

        // Config mocks
        vm.startPrank(daoAdmin);
        takasurePool.setNewContributionToken(address(usdc));
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConsumerMock));

        takasurePool.setNewReferralGateway(address(referralGateway));
        vm.stopPrank();
        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(takasurePool));

        // Give and approve USDC
        deal(address(usdc), referral, USDC_INITIAL_AMOUNT);
        deal(address(usdc), child, USDC_INITIAL_AMOUNT);
        deal(address(usdc), member, USDC_INITIAL_AMOUNT);
        vm.prank(referral);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(child);
        usdc.approve(address(referralGateway), USDC_INITIAL_AMOUNT);
        vm.prank(member);
        usdc.approve(address(takasurePool), USDC_INITIAL_AMOUNT);

        // Join the dao
        vm.prank(daoAdmin);
        takasurePool.setKYCStatus(member);
        // We simulate a request before the KYC
        _successResponse(address(bmConsumerMock));
        vm.prank(member);
        takasurePool.joinPool(CONTRIBUTION_AMOUNT, 5);

        ReferralGateway newImplementation = new ReferralGateway();

        vm.prank(takadao);
        referralGateway.upgradeToAndCall(
            address(newImplementation),
            abi.encodeCall(ReferralGateway.initializeNewVersion, (couponPool, couponRedeemer, 2))
        );

        deal(address(usdc), couponPool, 1000e6);

        vm.prank(couponPool);
        usdc.approve(address(referralGateway), 1000e6);

        vm.prank(daoAdmin);
        referralGateway.createDAO(tDaoName, true, true, 1743479999, 1e12, address(bmConsumerMock));
    }

    /*//////////////////////////////////////////////////////////////
                                    PREPAYS
        //////////////////////////////////////////////////////////////*/

    //======== coupon higher than contribution ========//
    function testCouponPrepaymentCase1() public {
        uint256 couponAmount = CONTRIBUTION_AMOUNT * 2;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            tDaoName,
            address(0),
            child,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);

        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);

        (uint256 contributionBeforeFee, , , ) = referralGateway.getPrepaidMember(child, tDaoName);

        assertEq(contributionBeforeFee, couponAmount);
    }

    //======== coupon equals than contribution ========//
    function testCouponPrepaymentCase2() public {
        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT,
            tDaoName,
            address(0),
            child,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);

        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);

        (uint256 contributionBeforeFee, , , ) = referralGateway.getPrepaidMember(child, tDaoName);

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT);
    }

    //======== coupon less than contribution ========//
    function testCouponPrepaymentCase3() public {
        uint256 couponAmount = CONTRIBUTION_AMOUNT;

        uint256 initialCouponPoolBalance = usdc.balanceOf(couponPool);

        vm.prank(couponRedeemer);
        referralGateway.payContributionOnBehalfOf(
            CONTRIBUTION_AMOUNT * 2,
            tDaoName,
            address(0),
            child,
            couponAmount
        );

        uint256 finalCouponPoolBalance = usdc.balanceOf(couponPool);

        assertEq(finalCouponPoolBalance, initialCouponPoolBalance - couponAmount);

        (uint256 contributionBeforeFee, , , ) = referralGateway.getPrepaidMember(child, tDaoName);

        assertEq(contributionBeforeFee, CONTRIBUTION_AMOUNT * 2);
    }
}
