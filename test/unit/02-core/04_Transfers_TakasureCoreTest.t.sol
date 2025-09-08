// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {DeployReserve} from "test/utils/05-DeployReserve.s.sol";
import {DeployManagers} from "test/utils/01-DeployManagers.s.sol";
import {AddAddressesAndRoles} from "test/utils/04-AddAddressesAndRoles.s.sol";
import {DeployModules} from "test/utils/03-DeployModules.s.sol";
import {HelperConfig} from "deploy/utils/configs/HelperConfig.s.sol";
import {AddressManager} from "contracts/managers/AddressManager.sol";
import {ModuleManager} from "contracts/managers/ModuleManager.sol";
import {TakasureReserve} from "contracts/core/TakasureReserve.sol";
import {BenefitModule} from "contracts/modules/BenefitModule.sol";
import {SubscriptionModule} from "contracts/modules/SubscriptionModule.sol";
import {KYCModule} from "contracts/modules/KYCModule.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {BenefitMember, Reserve} from "contracts/types/TakasureTypes.sol";
import {IUSDC} from "test/mocks/IUSDCmock.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

contract Transfers_TakasureCoreTest is StdCheats, Test {
    DeployManagers managersDeployer;
    AddAddressesAndRoles addressesAndRoles;
    DeployModules moduleDeployer;
    DeployReserve deployer;
    TakasureReserve takasureReserve;
    BenefitModule lifeBenefitModule;
    SubscriptionModule subscriptionModule;
    KYCModule kycModule;
    address kycProvider;
    address couponRedeemer;
    address takadao;
    IUSDC usdc;
    address public alice = makeAddr("alice");
    uint256 public constant USDC_INITIAL_AMOUNT = 1000e6; // 1000 USDC
    uint256 public constant CONTRIBUTION_AMOUNT = 225e6; // 225 USDC
    uint256 public constant DEPOSITED_ON_SUBSCRIPTION = 25e6;
    uint256 public constant YEAR = 365 days;

    function setUp() public {
        managersDeployer = new DeployManagers();
        addressesAndRoles = new AddAddressesAndRoles();
        moduleDeployer = new DeployModules();
        deployer = new DeployReserve();

        (
            HelperConfig.NetworkConfig memory config,
            AddressManager addressManager,
            ModuleManager moduleManager
        ) = managersDeployer.run();

        (takadao, , kycProvider, couponRedeemer, , ) = addressesAndRoles.run(
            addressManager,
            config,
            address(moduleManager)
        );

        (lifeBenefitModule, , kycModule, , , , subscriptionModule) = moduleDeployer.run(
            addressManager
        );

        takasureReserve = deployer.run(config, addressManager);

        usdc = IUSDC(config.contributionToken);

        // For easier testing there is a minimal USDC mock contract without restrictions
        deal(address(usdc), alice, USDC_INITIAL_AMOUNT);

        vm.startPrank(alice);
        usdc.approve(address(subscriptionModule), USDC_INITIAL_AMOUNT);
        usdc.approve(address(lifeBenefitModule), USDC_INITIAL_AMOUNT);
        vm.stopPrank();

        vm.prank(couponRedeemer);
        subscriptionModule.paySubscriptionOnBehalfOf(alice, address(0), 0, block.timestamp);

        vm.prank(kycProvider);
        kycModule.approveKYC(alice);
    }

    /*//////////////////////////////////////////////////////////////
                    JOIN POOL::TRANSFER AMOUNTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Test contribution amount is transferred to the contract when joins the pool
    function testTakasureCore_contributionAmountTransferToContractWhenJoinPool() public {
        uint256 takasureReserveBalanceBefore = usdc.balanceOf(address(takasureReserve));

        Reserve memory reserve = takasureReserve.getReserveValues();
        uint8 serviceFee = reserve.serviceFee;

        vm.prank(couponRedeemer);
        lifeBenefitModule.joinBenefitOnBehalfOf(alice, CONTRIBUTION_AMOUNT, (5 * YEAR), 0);

        uint256 takasureReserveBalanceAfter = usdc.balanceOf(address(takasureReserve));

        uint256 fee = (CONTRIBUTION_AMOUNT * serviceFee) / 100;
        uint256 deposited = CONTRIBUTION_AMOUNT - fee;

        assertEq(takasureReserveBalanceBefore, 0); // No one joined before
        assertGt(takasureReserveBalanceAfter, takasureReserveBalanceBefore);
        assertEq(takasureReserveBalanceAfter, takasureReserveBalanceBefore + deposited);
    }

    /// @dev Test service fee is transferred when the member joins the pool
    function testTakasureCore_serviceFeeAmountTransferedWhenJoinsPool() public {
        Reserve memory reserve = takasureReserve.getReserveValues();
        uint8 serviceFee = reserve.serviceFee;
        address serviceFeeReceiver = IAddressManager(takasureReserve.addressManager())
            .getProtocolAddressByName("FEE_CLAIM_ADDRESS")
            .addr;
        uint256 serviceFeeReceiverBalanceBefore = usdc.balanceOf(serviceFeeReceiver);

        vm.prank(couponRedeemer);
        lifeBenefitModule.joinBenefitOnBehalfOf(alice, CONTRIBUTION_AMOUNT, (5 * YEAR), 0);

        uint256 serviceFeeReceiverBalanceAfter = usdc.balanceOf(serviceFeeReceiver);

        assertGt(serviceFeeReceiverBalanceAfter, serviceFeeReceiverBalanceBefore);
    }
}
