// SPDX-License-Identifier: MIT

/**
 * @title UserRouter
 * @author Maikel Ordaz
 * @notice This contract allows an easier implementation of the user's actions
 */
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IEntryModule} from "contracts/interfaces/IEntryModule.sol";
import {IMemberModule} from "contracts/interfaces/IMemberModule.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";

pragma solidity 0.8.28;

contract UserRouter is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    ITakasureReserve private takasureReserve;
    IEntryModule private entryModule;
    IMemberModule private memberModule;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _takasureReserveAddress,
        address _entryModule,
        address _memberModule
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();

        takasureReserve = ITakasureReserve(_takasureReserveAddress);
        entryModule = IEntryModule(_entryModule);
        memberModule = IMemberModule(_memberModule);

        address takadaoOperator = takasureReserve.takadaoOperator();

        _grantRole(DEFAULT_ADMIN_ROLE, takadaoOperator);
        _grantRole(ModuleConstants.OPERATOR, takadaoOperator);
    }

    function joinPool(
        address parentWallet,
        uint256 contributionBeforeFee,
        uint256 membershipDuration
    ) external {
        entryModule.joinPool(msg.sender, parentWallet, contributionBeforeFee, membershipDuration);
    }

    function refund() external {
        entryModule.refund(msg.sender);
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

    function setTakasureReserve(
        address _takasureReserveAddress
    ) external onlyRole(ModuleConstants.OPERATOR) {
        takasureReserve = ITakasureReserve(_takasureReserveAddress);
    }

    function setEntryModule(address _entryModule) external onlyRole(ModuleConstants.OPERATOR) {
        entryModule = IEntryModule(_entryModule);
    }

    function setMemberModule(address _memberModule) external onlyRole(ModuleConstants.OPERATOR) {
        memberModule = IMemberModule(_memberModule);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.OPERATOR) {}
}
