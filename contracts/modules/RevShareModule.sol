//SPDX-License-Identifier: GPL-3.0

/**
 * @title RevShareModule
 * @author Maikel Ordaz
 * @dev Allow NFT holders to receive a share of the revenue generated by the platform
 * @dev Important notes:
 *      1. It will mint a new NFT to all users that deposit maximum contribution
 *      2. It will mint a new NFT per each 250USDC expends by a coupon buyer
 * @dev Upgradeable contract with UUPS pattern
 */
import {IModuleManager} from "contracts/interfaces/IModuleManager.sol";
import {IPrejoinModule} from "contracts/interfaces/IPrejoinModule.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";

import {ModuleState} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";

pragma solidity 0.8.28;

contract RevShareModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    TLDModuleImplementation,
    ERC721Upgradeable
{
    IModuleManager private moduleManager;
    IPrejoinModule private prejoinModule;
    ITakasureReserve private takasureReserve;

    ModuleState private moduleState;

    bool private prejoinActive;

    event OnTakasureReserveSet(address indexed takasureReserve);

    error RevShareModule__PrejoinStillActive();

    /// @custom:oz-upgrades-unsafe-allow-constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _operator,
        address _moduleManager,
        address _prejoinModule
    ) external initializer {
        AddressAndStates._notZeroAddress(_operator);
        AddressAndStates._notZeroAddress(_moduleManager);

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ERC721_init("RevShareNFT", "RSNFT");

        _grantRole(ModuleConstants.TAKADAO_OPERATOR, _operator);
        _grantRole(ModuleConstants.MODULE_MANAGER, _moduleManager);

        moduleManager = IModuleManager(_moduleManager);
        prejoinModule = IPrejoinModule(_prejoinModule);

        prejoinActive = true;
    }

    /**
     * @notice Set the module state
     *  @dev Only callble from the Module Manager
     */
    function setContractState(
        ModuleState newState
    ) external override onlyRole(ModuleConstants.MODULE_MANAGER) {
        moduleState = newState;
    }

    /**
     * @notice Set the Takasure Reserve contract when deployed
     */
    function setTakasureReserve(
        address _takasureReserve
    ) external onlyRole(ModuleConstants.TAKADAO_OPERATOR) {
        AddressAndStates._notZeroAddress(_takasureReserve);

        // To avoid unexpected behavior we need to ensure the prejoin is already disabled
        require(
            !moduleManager.isActiveModule(address(prejoinModule)),
            RevShareModule__PrejoinStillActive()
        );

        prejoinActive = false;
        takasureReserve = ITakasureReserve(_takasureReserve);

        emit OnTakasureReserveSet(_takasureReserve);
    }

    /**
     * @notice Needed override
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC721Upgradeable, AccessControlUpgradeable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.TAKADAO_OPERATOR) {}
}
