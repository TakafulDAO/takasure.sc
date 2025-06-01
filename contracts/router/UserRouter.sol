// SPDX-License-Identifier: MIT

/**
 * @title UserRouter
 * @author Maikel Ordaz
 * @notice This contract allows an easier implementation of the user's actions
 */
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {ISubscriptionModule} from "contracts/interfaces/ISubscriptionModule.sol";
import {IMemberModule} from "contracts/interfaces/IMemberModule.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

pragma solidity 0.8.28;

contract UserRouter is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    ISubscriptionModule private subscriptionModule;
    IMemberModule private memberModule;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _takasureReserveAddress,
        address _subscriptionModule,
        address _memberModule
    ) external initializer {
        AddressAndStates._notZeroAddress(_takasureReserveAddress);
        AddressAndStates._notZeroAddress(_subscriptionModule);
        AddressAndStates._notZeroAddress(_memberModule);

        __UUPSUpgradeable_init();
        __AccessControl_init();

        subscriptionModule = ISubscriptionModule(_subscriptionModule);
        memberModule = IMemberModule(_memberModule);

        address takadaoOperator = ITakasureReserve(_takasureReserveAddress).takadaoOperator();

        _grantRole(DEFAULT_ADMIN_ROLE, takadaoOperator);
        _grantRole(ModuleConstants.OPERATOR, takadaoOperator);
    }

    function paySubscription(
        address memberWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external {
        subscriptionModule.paySubscription(
            msg.sender,
            memberWallet,
            contributionBeforeFee,
            membershipDuration
        );
    }

    function refund() external {
        subscriptionModule.refund(msg.sender);
    }

    function payRecurringContribution() external {
        memberModule.payRecurringContribution(msg.sender);
    }

    function cancelMembership() external {
        memberModule.cancelMembership(msg.sender);
    }

    function cancelMembership(address memberWallet) external {
        memberModule.cancelMembership(memberWallet);
    }

    function defaultMember(address memberWallet) external {
        memberModule.defaultMember(memberWallet);
    }

    function setSubscriptionModule(
        address _subscriptionModule
    ) external onlyRole(ModuleConstants.OPERATOR) {
        AddressAndStates._notZeroAddress(_subscriptionModule);
        subscriptionModule = ISubscriptionModule(_subscriptionModule);
    }

    function setMemberModule(address _memberModule) external onlyRole(ModuleConstants.OPERATOR) {
        AddressAndStates._notZeroAddress(_memberModule);
        memberModule = IMemberModule(_memberModule);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.OPERATOR) {}
}
