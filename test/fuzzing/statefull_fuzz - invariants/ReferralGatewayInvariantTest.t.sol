// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, StdInvariant, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ReferralGatewayHandler} from "test/helpers/handlers/ReferralGatewayHandler.t.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";

contract ReferralGatewayInvariantTest is StdInvariant, Test {
    TestDeployProtocol deployer;
    ReferralGateway referralGateway;
    TakasureReserve takasureReserve;
    HelperConfig helperConfig;
    ReferralGatewayHandler handler;
    IUSDC usdc;
    address referralGatewayAddress;
    address reserve;
    address contributionTokenAddress;
    address daoAdmin;
    address operator;
    address public user = makeAddr("user");
    address public couponRedeemer = makeAddr("couponRedeemer");
    address couponPool = makeAddr("couponPool");
    uint256 operatorInitialBalance;
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            reserve,
            referralGatewayAddress,
            ,
            ,
            ,
            ,
            ,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        operator = config.takadaoOperator;
        daoAdmin = config.daoMultisig;

        // Assign implementations
        referralGateway = ReferralGateway(referralGatewayAddress);
        takasureReserve = TakasureReserve(reserve);
        usdc = IUSDC(contributionTokenAddress);

        deal(address(usdc), couponPool, 1000e6);

        vm.prank(couponPool);
        usdc.approve(address(referralGateway), type(uint256).max);

        vm.startPrank(operator);
        referralGateway.setCouponPoolAddress(couponPool);
        referralGateway.createDAO(true, true, block.timestamp + 31_536_000, 0);
        referralGateway.grantRole(keccak256("COUPON_REDEEMER"), couponRedeemer);
        vm.stopPrank();

        handler = new ReferralGatewayHandler(referralGateway, couponRedeemer);

        uint256 operatorAddressSlot = 2;
        bytes32 operatorAddressSlotBytes = vm.load(
            address(referralGateway),
            bytes32(uint256(operatorAddressSlot))
        );
        operator = address(uint160(uint256(operatorAddressSlotBytes)));

        operatorInitialBalance = usdc.balanceOf(operator);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ReferralGatewayHandler.payContributionOnBehalfOf.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @dev Invariant to check the fee is always transferred to the operator
    /// @dev Other asserts in the handler:
    /// 1. The fee deducted from the contribution is within the limits (4.475% - 27%)
    /// 2. The discount is within the limits (10% - 15%)
    function invariant_feeCalculatedCorrectly() public view {
        // This will also run some assertions in the handler
        (
            ,
            ,
            ,
            ,
            ,
            ,
            ,
            uint256 currentAmount,
            ,
            ,
            uint256 toRepool,
            uint256 referralReserve
        ) = referralGateway.getDAOData();
        uint256 contractBalance = usdc.balanceOf(address(referralGateway));
        assertEq(contractBalance, currentAmount + toRepool + referralReserve);
    }

    /// @dev Invariant to check if getters do not revert
    /// forge-config: default.invariant.runs = 100
    /// forge-config: default.invariant.depth = 2
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_gettersShouldNotRevert() public view {
        referralGateway.getDAOData();
        referralGateway.usdc();
    }
}
