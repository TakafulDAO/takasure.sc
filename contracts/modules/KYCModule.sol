//SPDX-License-Identifier: GPL-3.0

/**
 * @title KYCModule
 * @author Maikel Ordaz
 * @notice This contract manage the KYC flow
 * @dev Upgradeable contract with UUPS pattern
 */
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";
import {IMainStorageModule} from "contracts/interfaces/modules/IMainStorageModule.sol";

import {ModuleImplementation} from "contracts/modules/moduleUtils/ModuleImplementation.sol";
import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {
    AssociationMember,
    AssociationMemberState,
    ModuleState,
    ProtocolAddress
} from "contracts/types/TakasureTypes.sol";
import {Roles} from "contracts/helpers/libraries/constants/Roles.sol";
import {TakasureEvents} from "contracts/helpers/libraries/events/TakasureEvents.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

pragma solidity 0.8.28;

contract KYCModule is ModuleImplementation, Initializable, UUPSUpgradeable, ReentrancyGuardTransientUpgradeable {
    mapping(address member => bool) public isKYCed; // To check if a member is KYCed

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error KYCModule__ContributionRequired();
    error KYCModule__BenefitMultiplierRequestFailed(bytes errorResponse);
    error KYCModule__MemberAlreadyKYCed();

    /*//////////////////////////////////////////////////////////////
                             INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _addressManager, string calldata _moduleName) external initializer {
        __UUPSUpgradeable_init();
        __ReentrancyGuardTransient_init();

        addressManager = IAddressManager(_addressManager);
        moduleName = _moduleName;
    }

    /*//////////////////////////////////////////////////////////////
                                  KYC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Approves the KYC for a member.
     * @param memberWallet address of the member
     * @dev It reverts if the member is the zero address
     * @dev It reverts if the member is already KYCed
     */
    function approveKYC(address memberWallet) external onlyRole(Roles.KYC_PROVIDER, address(addressManager)) {
        AddressAndStates._onlyModuleState(
            ModuleState.Enabled,
            address(this),
            IAddressManager(addressManager).getProtocolAddressByName("PROTOCOL__MODULE_MANAGER").addr
        );
        AddressAndStates._notZeroAddress(memberWallet);

        require(!isKYCed[memberWallet], KYCModule__MemberAlreadyKYCed());

        IMainStorageModule mainStorageModule =
            IMainStorageModule(addressManager.getProtocolAddressByName("MODULE__MAIN_STORAGE").addr);
        AssociationMember memory newMember = mainStorageModule.getAssociationMember(memberWallet);

        // todo: uncomment when contributions are implemented from SubscriptionManagementModule PR
        // require(newMember.planId != 0 && !newMember.isRefunded, KYCModule__ContributionRequired());

        // We update the member values
        newMember.memberState = AssociationMemberState.Active; // Active state as the user is already paid the contribution and KYCed
        isKYCed[memberWallet] = true;

        mainStorageModule.updateAssociationMember(newMember);

        emit TakasureEvents.OnMemberKycVerified(newMember.memberId, memberWallet);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRole(Roles.OPERATOR, address(addressManager))
    {}
}
