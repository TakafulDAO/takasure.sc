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
    uint8 public SERVICE_FEE = 22;
    bool public isPreJoinEnabled;

    mapping(address proposedAmbassador => bool) public proposedAmbassadors;
    mapping(address ambassador => bool) public lifeDaoAmbassadors;
    mapping(address ambassador => uint256 rewards) public ambassadorRewards;

    event OnPreJoinEnabledChanged(bool indexed isPreJoinEnabled);
    event OnNewAmbassadorProposal(address indexed proposedAmbassador);
    event OnNewAmbassador(address indexed ambassador);

    error ReferralGateway__ZeroAddress();
    error ReferralGateway__OnlyProposedAmbassadors();

    modifier notZeroAddress(address _address) {
        if (_address == address(0)) {
            revert ReferralGateway__ZeroAddress();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address takadaoOperator
    ) external notZeroAddress(takadaoOperator) initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(takadaoOperator);
        __Ownable2Step_init();

        isPreJoinEnabled = true;
    }

    function proposeAsAmbassador() external {
        _proposeAsAmbassador(msg.sender);
    }

    function proposeAsAmbassador(
        address propossedAmbassador
    ) external notZeroAddress(propossedAmbassador) {
        _proposeAsAmbassador(propossedAmbassador);
    }

    function approveAsAmbassador(address ambassador) external notZeroAddress(ambassador) onlyOwner {
        if (!proposedAmbassadors[ambassador]) {
            revert ReferralGateway__OnlyProposedAmbassadors();
        }
        lifeDaoAmbassadors[ambassador] = true;

        emit OnNewAmbassador(ambassador);
    }

    function setPreJoinEnabled(bool _isPreJoinEnabled) external onlyOwner {
        isPreJoinEnabled = _isPreJoinEnabled;

        emit OnPreJoinEnabledChanged(_isPreJoinEnabled);
    }

    function _proposeAsAmbassador(address _propossedAmbassador) internal {
        proposedAmbassadors[_propossedAmbassador] = true;

        emit OnNewAmbassadorProposal(_propossedAmbassador);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
