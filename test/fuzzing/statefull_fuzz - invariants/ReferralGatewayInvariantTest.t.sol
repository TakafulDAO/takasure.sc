// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, StdInvariant, console2} from "forge-std/Test.sol";
import {TestDeployTakasure} from "test/utils/TestDeployTakasure.s.sol";
import {ReferralGateway} from "contracts/referrals/ReferralGateway.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {ReferralGatewayHandler} from "test/helpers/handlers/ReferralGatewayHandler.t.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasurePool} from "contracts/takasure/TakasurePool.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";

contract ReferralGatewayInvariantTest is StdInvariant, Test {
    TestDeployTakasure deployer;
    ReferralGateway referralGateway;
    TakasurePool takasurePool;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    ReferralGatewayHandler handler;

    IUSDC usdc;

    address proxy;
    address daoProxy;
    address contributionTokenAddress;
    address daoAdmin;
    address operator;
    address public user = makeAddr("user");
    uint256 operatorInitialBalance;
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    string constant DAO_NAME = "The LifeDAO";

    function setUp() public {
        deployer = new TestDeployTakasure();
        (, bmConsumerMock, daoProxy, proxy, contributionTokenAddress, , helperConfig) = deployer
            .run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        daoAdmin = config.daoMultisig;

        // Assign implementations
        referralGateway = ReferralGateway(address(proxy));
        takasurePool = TakasurePool(address(daoProxy));
        usdc = IUSDC(contributionTokenAddress);

        // Config mocks
        vm.startPrank(daoAdmin);
        takasurePool.setNewContributionToken(address(usdc));
        takasurePool.setNewBenefitMultiplierConsumer(address(bmConsumerMock));
        takasurePool.setNewReferralGateway(address(referralGateway));
        vm.stopPrank();

        vm.prank(msg.sender);
        bmConsumerMock.setNewRequester(address(takasurePool));

        vm.prank(daoAdmin);
        referralGateway.createDAO(
            DAO_NAME,
            true,
            true,
            block.timestamp + 31_536_000,
            0,
            address(bmConsumerMock)
        );

        handler = new ReferralGatewayHandler(referralGateway);

        uint256 operatorAddressSlot = 2;
        bytes32 operatorAddressSlotBytes = vm.load(
            address(referralGateway),
            bytes32(uint256(operatorAddressSlot))
        );
        operator = address(uint160(uint256(operatorAddressSlotBytes)));

        operatorInitialBalance = usdc.balanceOf(operator);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = ReferralGatewayHandler.payContribution.selector;

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
            uint256 currentAmount,
            ,
            ,
            uint256 toRepool,
            uint256 referralReserve
        ) = referralGateway.getDAOData(DAO_NAME);
        uint256 contractBalance = usdc.balanceOf(address(referralGateway));

        assertEq(contractBalance, currentAmount + toRepool + referralReserve);
    }

    /// @dev Invariant to check if getters do not revert
    /// forge-config: default.invariant.runs = 100
    /// forge-config: default.invariant.depth = 2
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_gettersShouldNotRevert() public view {
        referralGateway.getDAOData(DAO_NAME);
        referralGateway.usdc();
    }
}
