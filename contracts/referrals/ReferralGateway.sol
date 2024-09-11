// SPDX-License-Identifier: GPL-3.0

/**
 * @title ReferralGateway
 * @author Maikel Ordaz
 * @dev This contract will manage all the functionalities related to the referral system and pre-joins
 *      to the LifeDao protocol
 * @dev Upgradeable contract with UUPS pattern
 */

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

pragma solidity 0.8.25;

contract ReferralGateway is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    bool public isPreJoinEnabled;

    event OnPreJoinEnabledChanged(bool isPreJoinEnabled);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address takadaoOperator) external initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(takadaoOperator);
        __Ownable2Step_init();

        isPreJoinEnabled = true;
    }

    function setPreJoinEnabled(bool _isPreJoinEnabled) external onlyOwner {
        isPreJoinEnabled = _isPreJoinEnabled;

        emit OnPreJoinEnabledChanged(_isPreJoinEnabled);
    }

    function _getServiceFee() internal pure returns (uint256) {
        // TODO: After the size optimization this must be a call to the correct contract and method. Until then, it is hardcoded
        return 22;
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
