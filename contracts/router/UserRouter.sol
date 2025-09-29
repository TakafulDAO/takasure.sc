// SPDX-License-Identifier: MIT

/**
 * @title UserRouter
 * @author Maikel Ordaz
 * @notice This contract allows an easier implementation of the user's actions
 */
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {ISubscriptionModule} from "contracts/interfaces/ISubscriptionModule.sol";
import {IMemberModule} from "contracts/interfaces/IMemberModule.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {ProtocolAddress} from "contracts/types/TakasureTypes.sol";

pragma solidity 0.8.28;

contract UserRouter is Initializable, UUPSUpgradeable {
    IAddressManager private addressManager;

    error UserRouter__NotAuthorizedCaller();

    modifier onlyRole(bytes32 role) {
        require(
            AddressAndStates._checkRole(role, address(addressManager)),
            UserRouter__NotAuthorizedCaller()
        );
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _takasureReserveAddress) external initializer {
        AddressAndStates._notZeroAddress(_takasureReserveAddress);

        __UUPSUpgradeable_init();

        addressManager = IAddressManager(
            ITakasureReserve(_takasureReserveAddress).addressManager()
        );
    }

    function paySubscription(
        address memberWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external {
        ISubscriptionModule subscriptionModule = _getSubscriptionModule();

        subscriptionModule.paySubscription(
            msg.sender,
            memberWallet,
            contributionBeforeFee,
            membershipDuration
        );
    }

    function refund() external {
        ISubscriptionModule subscriptionModule = _getSubscriptionModule();

        subscriptionModule.refund(msg.sender);
    }

    function payRecurringContribution() external {
        IMemberModule memberModule = _getMemberModule();

        memberModule.payRecurringContribution(msg.sender);
    }

    function cancelMembership() external {
        IMemberModule memberModule = _getMemberModule();

        memberModule.cancelMembership(msg.sender);
    }

    function cancelMembership(address memberWallet) external {
        IMemberModule memberModule = _getMemberModule();

        memberModule.cancelMembership(memberWallet);
    }

    function defaultMember(address memberWallet) external {
        IMemberModule memberModule = _getMemberModule();

        memberModule.defaultMember(memberWallet);
    }

    function _getSubscriptionModule()
        internal
        view
        returns (ISubscriptionModule subscriptionModule_)
    {
        subscriptionModule_ = ISubscriptionModule(
            addressManager.getProtocolAddressByName("SUBSCRIPTION_MODULE").addr
        );
    }

    function _getMemberModule() internal view returns (IMemberModule memberModule_) {
        memberModule_ = IMemberModule(
            addressManager.getProtocolAddressByName("MEMBER_MODULE").addr
        );
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(Roles.OPERATOR) {}
}
