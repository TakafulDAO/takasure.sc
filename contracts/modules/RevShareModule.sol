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
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC721EnumerableUpgradeable, ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";

import {ModuleState} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {Member} from "contracts/types/TakasureTypes.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract RevShareModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    TLDModuleImplementation,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable
{
    using SafeERC20 for IERC20;

    IModuleManager private moduleManager;
    ITakasureReserve private takasureReserve;
    IERC20 private usdc; // Revenue token

    address private takadaoOperator;

    ModuleState private moduleState;

    uint256 public constant MAX_CONTRIBUTION = 250e6; // 250 USDC
    uint256 public constant TOTAL_SUPPLY = 18_000;
    uint256 private constant DECIMAL_CORRECTION = 1e6;

    uint256 private revenueRate;
    uint256 private lastUpdatedTimestamp; // Last time the rewards were updated
    uint256 private revenuePerNFTOwned;

    uint256 public latestTokenId;

    mapping(address => uint256) public userRevenuePerNFTPaid;
    mapping(address => uint256) public revenues;

    // Tracks if a member has claimed the NFTs, it does not track coupon buyers
    mapping(address member => bool) public claimedNFTs;
    mapping(uint256 tokenId => bool active) public isNFTActive;
    // Track coupon amount related values
    mapping(address couponBuyer => uint256 couponAmount) public couponAmountsByBuyer; // How much a coupon buyer has spent
    mapping(address couponBuyer => uint256 couponRedeemedAmount)
        public couponRedeemedAmountsByBuyer; // How much a coupon buyer has redeemed. It will be reset when the coupon mints new NFTs

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnCouponAmountByBuyerIncreased(address indexed buyer, uint256 amount);
    event OnCouponAmountRedeemedByBuyerIncreased(address indexed buyer, uint256 amount);
    event OnTakasureReserveSet(address indexed takasureReserve);
    event OnRevShareNFTMinted(address indexed member, uint256 tokenId);
    event OnRevShareNFTActivated(address indexed member, uint256 tokenId);

    error RevShareModule__MaxSupplyReached();
    error RevShareModule__NotAllowedToMint();
    error RevShareModule__NoRevenueToClaim();
    error RevShareModule__NotNFTOwner();
    error RevShareModule__NotZeroAmount();
    error RevShareModule__NotEnoughRedeemedAmount();
    error RevShareModule__MintNFTFirst();

    /// @custom:oz-upgrades-unsafe-allow-constructor
    constructor() {
        _disableInitializers();
    }

    // TODO: Initialize the URI when set, skip for now just for easier testing, but needed for production
    function initialize(
        address _operator,
        address _moduleManager,
        address _takasureReserve,
        address _usdc
    ) external initializer {
        AddressAndStates._notZeroAddress(_operator);
        AddressAndStates._notZeroAddress(_moduleManager);
        AddressAndStates._notZeroAddress(_takasureReserve);
        AddressAndStates._notZeroAddress(_usdc);

        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ERC721_init("RevShareNFT", "RSNFT");
        __ERC721Enumerable_init();

        _grantRole(ModuleConstants.TAKADAO_OPERATOR, _operator);
        _grantRole(ModuleConstants.MODULE_MANAGER, _moduleManager);

        moduleManager = IModuleManager(_moduleManager);
        takasureReserve = ITakasureReserve(_takasureReserve);
        usdc = IERC20(_usdc);
        takadaoOperator = _operator;

        revenueRate = 1;

        emit OnTakasureReserveSet(_takasureReserve);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the module state
     *  @dev Only callble from the Module Manager
     */
    function setContractState(
        ModuleState newState
    ) external override onlyRole(ModuleConstants.MODULE_MANAGER) {
        moduleState = newState;
    }

    // TODO: Instead of operator, can be the backend
    function increaseCouponAmountByBuyer(
        address buyer,
        uint256 amount
    ) external onlyRole(ModuleConstants.COUPON_REDEEMER) {
        AddressAndStates._notZeroAddress(buyer);
        require(amount > 0, RevShareModule__NotZeroAmount());

        couponAmountsByBuyer[buyer] += amount;

        emit OnCouponAmountByBuyerIncreased(buyer, amount);
    }

    // TODO: Instead of operator, can be the backend or the entry module
    function increaseCouponRedeemedAmountByBuyer(
        address buyer,
        uint256 amount
    ) external onlyRole(ModuleConstants.TAKADAO_OPERATOR) {
        AddressAndStates._notZeroAddress(buyer);
        require(amount > 0, RevShareModule__NotZeroAmount());

        couponRedeemedAmountsByBuyer[buyer] += amount;

        emit OnCouponAmountRedeemedByBuyerIncreased(buyer, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  MINT
    //////////////////////////////////////////////////////////////*/

    function mint() external {
        require(latestTokenId < TOTAL_SUPPLY, RevShareModule__MaxSupplyReached());

        // Check if the caller must be KYCed and paid the maximum contribution
        Member memory member = takasureReserve.getMemberFromAddress(msg.sender);
        require(
            member.isKYCVerified && member.contribution == MAX_CONTRIBUTION,
            RevShareModule__NotAllowedToMint()
        );

        // Update the revenues
        _updateRevenue(msg.sender);
        _updateRevenue(takadaoOperator);

        ++latestTokenId;

        // All NFTs minted by normal users are active from the start
        isNFTActive[latestTokenId] = true;
        claimedNFTs[msg.sender] = true;
        _safeMint(msg.sender, latestTokenId);

        emit OnRevShareNFTMinted(msg.sender, latestTokenId);
    }

    function batchMint() external {
        require(latestTokenId < TOTAL_SUPPLY, RevShareModule__MaxSupplyReached());
        require(
            couponAmountsByBuyer[msg.sender] >= MAX_CONTRIBUTION,
            RevShareModule__NotAllowedToMint()
        );

        // Update the revenues
        _updateRevenue(msg.sender);
        _updateRevenue(takadaoOperator);

        // Check how many NFTs the coupon buyer can mint
        uint256 maxNFTsAllowed = couponAmountsByBuyer[msg.sender] / MAX_CONTRIBUTION;
        // In case the coupon buyer have already minted some NFTs, we take that into account
        uint256 currentAllowedToMint = maxNFTsAllowed - balanceOf(msg.sender);

        uint256 firstTokenId = latestTokenId + 1;
        uint256 lastTokenId = latestTokenId + currentAllowedToMint;

        latestTokenId = lastTokenId;

        // Non NFT will be active for coupon buyers until 250 USDC in coupons are redeemed
        for (uint256 i = firstTokenId; i <= lastTokenId; ++i) {
            _safeMint(msg.sender, i);

            emit OnRevShareNFTMinted(msg.sender, i);
        }
    }

    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override(ERC721Upgradeable, IERC721) {
        _updateRevenue(from);
        _updateRevenue(to);

        super.transferFrom(from, to, tokenId);
    }

    function activateNFT() external {
        require(
            couponRedeemedAmountsByBuyer[msg.sender] >= MAX_CONTRIBUTION,
            RevShareModule__NotEnoughRedeemedAmount()
        );

        uint256 bal = balanceOf(msg.sender);

        require(bal > 0, RevShareModule__MintNFTFirst());

        uint256 redeemed = couponRedeemedAmountsByBuyer[msg.sender];
        uint256 tokensToActivate = redeemed / MAX_CONTRIBUTION;
        couponRedeemedAmountsByBuyer[msg.sender] -= tokensToActivate * MAX_CONTRIBUTION;

        uint256 activeNFTs;

        for (uint256 i; i < bal; ++i) {
            uint256 tokenId = tokenOfOwnerByIndex(msg.sender, i);

            if (!isNFTActive[tokenId]) {
                isNFTActive[tokenId] = true;
                ++activeNFTs;

                emit OnRevShareNFTActivated(msg.sender, tokenId);

                if (activeNFTs == tokensToActivate) break;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                             CLAIM REVENUE
    //////////////////////////////////////////////////////////////*/

    function claimRevenue() external {
        require(balanceOf(msg.sender) > 0, RevShareModule__NotNFTOwner());

        // Update the revenues
        _updateRevenue(msg.sender);

        uint256 revenue = revenues[msg.sender];

        require(revenue > 0, RevShareModule__NoRevenueToClaim());

        revenues[msg.sender] = 0;
        usdc.safeTransfer(msg.sender, revenue);
    }

    function getRevenuePerNFT() external view returns (uint256) {
        return _revenuePerNFT();
    }

    /**
     * @notice How much a user have earned in total
     */
    function getRevenueEarnedByUser(address user) external view returns (uint256) {
        return _revenueEarnedByUser(user);
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _updateRevenue(address _user) internal {
        revenuePerNFTOwned = _revenuePerNFT();
        lastUpdatedTimestamp = block.timestamp;

        revenues[_user] = _revenueEarnedByUser(_user);
        userRevenuePerNFTPaid[_user] = revenuePerNFTOwned;
    }

    function _revenuePerNFT() internal view returns (uint256) {
        // TODO: Check the 1e6
        return (revenuePerNFTOwned +
            ((revenueRate * (block.timestamp - lastUpdatedTimestamp) * 1e6) / TOTAL_SUPPLY));
    }

    function _revenueEarnedByUser(address _user) internal view returns (uint256) {
        // TODO: Check the 1e6
        uint256 bal = balanceOf(msg.sender);

        uint256 activeNFTs;

        for (uint256 i; i < bal; ++i) {
            uint256 tokenId = tokenOfOwnerByIndex(msg.sender, i);
            if (isNFTActive[tokenId]) ++activeNFTs;
        }

        return (((activeNFTs * (_revenuePerNFT() - userRevenuePerNFTPaid[_user])) / 1e6) +
            revenues[_user]);
    }

    function _safeTransfer(
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) internal override {
        _updateRevenue(from);
        _updateRevenue(to);

        super._safeTransfer(from, to, tokenId, data);
    }

    /// @notice Needed override
    function _update(
        address to,
        uint256 tokenId,
        address auth
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) returns (address) {
        return super._update(to, tokenId, auth);
    }

    /// @notice Needed override
    function _increaseBalance(
        address account,
        uint128 amount
    ) internal override(ERC721Upgradeable, ERC721EnumerableUpgradeable) {
        super._increaseBalance(account, amount);
    }

    /// @notice Needed override
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        virtual
        override(ERC721Upgradeable, ERC721EnumerableUpgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.TAKADAO_OPERATOR) {}
}
