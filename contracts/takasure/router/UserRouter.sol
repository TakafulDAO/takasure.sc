// SPDX-License-Identifier: MIT

/**
 * @title UserRouter
 * @author Maikel Ordaz
 * @notice This contract allows an easier implementation of the user's actions
 */
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IJoinModule} from "contracts/interfaces/IJoinModule.sol";
import {IMembersModule} from "contracts/interfaces/IMembersModule.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";

import {ModuleConstants} from "contracts/libraries/ModuleConstants.sol";

pragma solidity 0.8.28;

contract UserRouter is Initializable, UUPSUpgradeable, AccessControlUpgradeable {
    ITakasureReserve private takasureReserve;
    IJoinModule private joinModule;
    IMembersModule private membersModule;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _takasureReserveAddress,
        address _joinModule,
        address _membersModule
    ) external initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();

        takasureReserve = ITakasureReserve(_takasureReserveAddress);
        joinModule = IJoinModule(_joinModule);
        membersModule = IMembersModule(_membersModule);

        address takadaoOperator = takasureReserve.takadaoOperator();

        _grantRole(DEFAULT_ADMIN_ROLE, takadaoOperator);
        _grantRole(ModuleConstants.TAKADAO_OPERATOR, takadaoOperator);
    }

    function joinPool(uint256 contributionBeforeFee, uint256 membershipDuration) external {
        joinModule.joinPool(msg.sender, contributionBeforeFee, membershipDuration);
    }

    function refund() external {
        joinModule.refund(msg.sender);
    }

    function payRecurringContribution() external {
        membersModule.payRecurringContribution(msg.sender);
    }

    function cancelMembership() external {
        membersModule.cancelMembership(msg.sender);
    }

    function cancelMembership(address memberWallet) external {
        membersModule.cancelMembership(memberWallet);
    }

    function setTakasureReserve(
        address _takasureReserveAddress
    ) external onlyRole(ModuleConstants.TAKADAO_OPERATOR) {
        takasureReserve = ITakasureReserve(_takasureReserveAddress);
    }

    function setJoinModule(
        address _joinModule
    ) external onlyRole(ModuleConstants.TAKADAO_OPERATOR) {
        joinModule = IJoinModule(_joinModule);
    }

    function setMembersModule(
        address _membersModule
    ) external onlyRole(ModuleConstants.TAKADAO_OPERATOR) {
        membersModule = IMembersModule(_membersModule);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.TAKADAO_OPERATOR) {}
}
