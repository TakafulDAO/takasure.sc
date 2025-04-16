// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

import {Test, StdInvariant, console2} from "forge-std/Test.sol";
import {TestDeployProtocol} from "test/utils/TestDeployProtocol.s.sol";
import {PrejoinModule} from "contracts/modules/PrejoinModule.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {PrejoinModuleHandler} from "test/helpers/handlers/PrejoinModuleHandler.t.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {BenefitMultiplierConsumerMock} from "test/mocks/BenefitMultiplierConsumerMock.sol";

contract PrejoinModuleInvariantTest is StdInvariant, Test {
    TestDeployProtocol deployer;
    PrejoinModule prejoinModule;
    TakasureReserve takasureReserve;
    BenefitMultiplierConsumerMock bmConsumerMock;
    HelperConfig helperConfig;
    PrejoinModuleHandler handler;
    IUSDC usdc;
    address prejoinModuleAddress;
    address reserve;
    address contributionTokenAddress;
    address daoAdmin;
    address operator;
    address public user = makeAddr("user");
    uint256 operatorInitialBalance;
    uint256 public constant USDC_INITIAL_AMOUNT = 100e6; // 100 USDC
    string constant DAO_NAME = "The LifeDAO";

    function setUp() public {
        deployer = new TestDeployProtocol();
        (
            ,
            bmConsumerMock,
            reserve,
            prejoinModuleAddress,
            ,
            ,
            ,
            ,
            contributionTokenAddress,
            ,
            helperConfig
        ) = deployer.run();

        HelperConfig.NetworkConfig memory config = helperConfig.getConfigByChainId(block.chainid);
        daoAdmin = config.daoMultisig;

        // Assign implementations
        prejoinModule = PrejoinModule(prejoinModuleAddress);
        takasureReserve = TakasureReserve(reserve);
        usdc = IUSDC(contributionTokenAddress);

        // Config mocks
        vm.startPrank(daoAdmin);
        takasureReserve.setNewContributionToken(contributionTokenAddress);
        takasureReserve.setNewBenefitMultiplierConsumerAddress(address(bmConsumerMock));
        vm.stopPrank();

        vm.prank(bmConsumerMock.admin());
        bmConsumerMock.setNewRequester(prejoinModuleAddress);

        vm.startPrank(daoAdmin);
        prejoinModule.createDAO(
            true,
            true,
            block.timestamp + 31_536_000,
            0,
            address(bmConsumerMock)
        );
        vm.stopPrank();

        handler = new PrejoinModuleHandler(prejoinModule);

        uint256 operatorAddressSlot = 2;
        bytes32 operatorAddressSlotBytes = vm.load(
            address(prejoinModule),
            bytes32(uint256(operatorAddressSlot))
        );
        operator = address(uint160(uint256(operatorAddressSlotBytes)));

        operatorInitialBalance = usdc.balanceOf(operator);

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PrejoinModuleHandler.payContribution.selector;
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
            uint256 currentAmount,
            ,
            ,
            uint256 toRepool,
            uint256 referralReserve
        ) = prejoinModule.getDAOData();
        uint256 contractBalance = usdc.balanceOf(address(prejoinModule));
        assertEq(contractBalance, currentAmount + toRepool + referralReserve);
    }

    /// @dev Invariant to check if getters do not revert
    /// forge-config: default.invariant.runs = 100
    /// forge-config: default.invariant.depth = 2
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_gettersShouldNotRevert() public view {
        prejoinModule.getDAOData();
        prejoinModule.usdc();
    }
}
