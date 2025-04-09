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
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {ERC721EnumerableUpgradeable, ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/extensions/ERC721EnumerableUpgradeable.sol";
import {TLDModuleImplementation} from "contracts/modules/moduleUtils/TLDModuleImplementation.sol";

import {ModuleState} from "contracts/types/TakasureTypes.sol";
import {ModuleConstants} from "contracts/helpers/libraries/constants/ModuleConstants.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

pragma solidity 0.8.28;

contract RevShareModule is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    TLDModuleImplementation,
    ERC721Upgradeable,
    ERC721EnumerableUpgradeable
{
    using SafeERC20 for IERC20;

    ITakasureReserve private takasureReserve;
    IERC20 private usdc; // Revenue token

    enum Operation {
        SINGLE_MINT,
        ACTIVATE_NFT
    }

    ModuleState private moduleState;

    address private takadaoOperator;

    uint256 public constant MAX_CONTRIBUTION = 250e6; // 250 USDC
    uint256 public constant MAX_SUPPLY = 18_000;
    uint256 private constant DECIMAL_CORRECTION = 1e6;

    uint256 private revenueRate;
    uint256 public lastUpdatedTimestamp; // Last time the rewards were updated
    uint256 public revenuePerNFTOwned;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    mapping(address => uint256) public userRevenuePerNFTPaid;
    mapping(address => uint256) public revenues;

    // Tracks if a member has claimed the NFTs, it does not track coupon buyers
    mapping(address member => bool) public claimedNFTs;
    mapping(uint256 tokenId => bool active) public isNFTActive;
    // Track coupon related values
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
    event OnRevShareNFTActivated(address indexed couponBuyer, uint256 tokenId);
    event OnRevenueClaimed(address indexed member, uint256 amount);

    error RevShareModule__MaxSupplyReached();
    error RevShareModule__NotAllowedToMint();
    error RevShareModule__NoRevenueToClaim();
    error RevShareModule__NotNFTOwner();
    error RevShareModule__NotZeroAmount();
    error RevShareModule__NotEnoughRedeemedAmount();
    error RevShareModule__MintNFTFirst();
    error RevShareModule__NotAllowed();
    error RevShareModule__NotActiveToken();
    error RevShareModule__AlreadySetCoupon();

    /// @custom:oz-upgrades-unsafe-allow-constructor
    constructor() {
        _disableInitializers();
    }

    // TODO: Initialize the URI when set, skip for now just for easier testing, but needed for production
    // ? New role for the backend here?
    function initialize(
        address _operator,
        address _minter,
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
        __ReentrancyGuardTransient_init();
        __ERC721_init("RevShareNFT", "RSNFT");
        __ERC721Enumerable_init();

        _grantRole(0x00, _operator);
        _grantRole(ModuleConstants.TAKADAO_OPERATOR, _operator);
        _grantRole(ModuleConstants.MODULE_MANAGER, _moduleManager);
        _grantRole(MINTER_ROLE, _minter);

        takasureReserve = ITakasureReserve(_takasureReserve);
        usdc = IERC20(_usdc);
        takadaoOperator = _operator;

        revenueRate = 1;
        lastUpdatedTimestamp = block.timestamp;

        emit OnTakasureReserveSet(_takasureReserve);
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the module state
     *  @dev Only callable from the Module Manager
     */
    function setContractState(
        ModuleState newState
    ) external override onlyRole(ModuleConstants.MODULE_MANAGER) {
        moduleState = newState;
    }

    function increaseCouponAmountByBuyer(
        address buyer,
        uint256 amount
    ) external onlyRole(ModuleConstants.COUPON_REDEEMER) {
        AddressAndStates._notZeroAddress(buyer);
        require(amount > 0, RevShareModule__NotZeroAmount());

        couponAmountsByBuyer[buyer] += amount;

        emit OnCouponAmountByBuyerIncreased(buyer, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  MINT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mint single token to a user or activate an existing token from a coupon buyer
     * @param operation The operation to perform, either mint or activate
     * @param member The address of the member to mint a single NFT
     * @param couponBuyer The address of the coupon buyer to activate the NFT, only if possible
     * @dev Only callable by someone with the MINTER_ROLE
     */
    function mintOrActivate(
        Operation operation,
        address member,
        address couponBuyer,
        uint256 amount
    ) external onlyRole(MINTER_ROLE) {
        if (operation == Operation.SINGLE_MINT) {
            _mintSingle(member);
        } else {
            _activateSingle(couponBuyer, amount);
        }
    }

    /**
     * @notice Mint multiple tokens to a coupon buyer
     * @param couponBuyer The address of the coupon buyer to mint the NFTs
     * @param couponAmount The amount of USDC bought by the coupon buyer
     * @dev Only callable by someone with the MINTER_ROLE
     */
    function batchMint(
        address couponBuyer,
        uint256 couponAmount
    ) external nonReentrant onlyRole(MINTER_ROLE) {
        AddressAndStates._notZeroAddress(couponBuyer);
        require(couponAmount > 0, RevShareModule__NotZeroAmount());
        require(totalSupply() < MAX_SUPPLY, RevShareModule__MaxSupplyReached());

        uint256 totalCouponAmount = couponAmountsByBuyer[couponBuyer] + couponAmount;

        // If the new coupon amount is less than the max contribution, we only increase the coupon amount
        // in case the coupon buyer will purchase more coupons in the future
        if (totalCouponAmount < MAX_CONTRIBUTION) {
            couponAmountsByBuyer[couponBuyer] = totalCouponAmount;
            emit OnCouponAmountByBuyerIncreased(couponBuyer, couponAmount);

            // We finish execution
            return;
        }

        // Check how many NFTs the coupon buyer can mint
        uint256 maxNFTsAllowed = totalCouponAmount / MAX_CONTRIBUTION; // 550 / 250 = 2.2 => 2 NFTs

        // Update the coupon amount for the coupon buyer with the remaining amount, not used for minting
        couponAmountsByBuyer[couponBuyer] = totalCouponAmount - (maxNFTsAllowed * MAX_CONTRIBUTION);

        uint256 currentTokenId = totalSupply();

        uint256 firstNewTokenId = currentTokenId + 1;
        uint256 lastNewTokenId = currentTokenId + maxNFTsAllowed;

        // Non NFT will be active for coupon buyers until 250 USDC in coupons are redeemed
        for (uint256 i = firstNewTokenId; i <= lastNewTokenId; ++i) {
            _safeMint(msg.sender, i);

            emit OnRevShareNFTMinted(msg.sender, i);
        }
    }

    /**
     * @notice Mint a single token to a user
     * @param _member The address of the member to mint a single NFT
     * @dev All NFTs minted to normal members are active from the start
     */
    function _mintSingle(address _member) internal nonReentrant {
        AddressAndStates._notZeroAddress(_member);
        require(totalSupply() < MAX_SUPPLY, RevShareModule__MaxSupplyReached());
        require(!claimedNFTs[_member], RevShareModule__NotAllowedToMint());

        uint256 currentTokenId = totalSupply();
        uint256 newTokenId = currentTokenId + 1;

        // Update the revenues
        _updateRevenue(_member);
        _updateRevenue(takadaoOperator);

        // All NFTs minted to normal members are active from the start
        isNFTActive[newTokenId] = true;
        claimedNFTs[_member] = true;

        _safeMint(_member, newTokenId);

        emit OnRevShareNFTMinted(_member, newTokenId);
    }

    /**
     * @notice Activate a single token from a coupon buyer
     * @param _couponBuyer The address of the coupon buyer to activate the NFT
     * @param _amount The amount of USDC redeemed by the coupon buyer
     */
    function _activateSingle(address _couponBuyer, uint256 _amount) internal {
        AddressAndStates._notZeroAddress(_couponBuyer);
        uint256 bal = balanceOf(_couponBuyer);
        require(bal > 0, RevShareModule__MintNFTFirst());

        uint256 currentRedeemedAmount = couponRedeemedAmountsByBuyer[_couponBuyer];
        uint256 newRedeemedAmount = currentRedeemedAmount + _amount;

        // If the new redeemed amount is less than the max contribution, we only increase the redeemed amount
        if (newRedeemedAmount < MAX_CONTRIBUTION) {
            couponRedeemedAmountsByBuyer[_couponBuyer] = newRedeemedAmount;
            emit OnCouponAmountRedeemedByBuyerIncreased(_couponBuyer, _amount);

            // We finish execution
            return;
        }

        couponRedeemedAmountsByBuyer[_couponBuyer] = newRedeemedAmount - MAX_CONTRIBUTION;

        // Update the revenues
        _updateRevenue(_couponBuyer);
        _updateRevenue(takadaoOperator);

        // It is only possible to activate one NFT at a time, so we break the loop after finding the first inactive one
        for (uint256 i; i < bal; ++i) {
            uint256 tokenId = tokenOfOwnerByIndex(_couponBuyer, i);
            if (!isNFTActive[tokenId]) {
                isNFTActive[tokenId] = true;
                emit OnRevShareNFTActivated(_couponBuyer, tokenId);
                break;
            }
        }
    }

    // function transfer(address to, uint256 tokenId) external {
    //     require(isNFTActive[tokenId], RevShareModule__NotActiveToken());

    //     _updateRevenue(msg.sender);
    //     _updateRevenue(to);

    //     _safeTransfer(msg.sender, to, tokenId, "");
    // }

    // function transferFrom(
    //     address from,
    //     address to,
    //     uint256 tokenId
    // ) public override(ERC721Upgradeable, IERC721) {
    //     require(isNFTActive[tokenId], RevShareModule__NotActiveToken());

    //     _updateRevenue(from);
    //     _updateRevenue(to);

    //     super.transferFrom(from, to, tokenId);
    // }

    // function activateNFT() external {
    //     require(
    //         couponRedeemedAmountsByBuyer[msg.sender] >= MAX_CONTRIBUTION,
    //         RevShareModule__NotEnoughRedeemedAmount()
    //     );

    //     uint256 bal = balanceOf(msg.sender);

    //     require(bal > 0, RevShareModule__MintNFTFirst());

    //     // Update the revenues
    //     _updateRevenue(msg.sender);
    //     _updateRevenue(takadaoOperator);

    //     uint256 redeemed = couponRedeemedAmountsByBuyer[msg.sender];
    //     uint256 tokensToActivate = redeemed / MAX_CONTRIBUTION;
    //     couponRedeemedAmountsByBuyer[msg.sender] -= tokensToActivate * MAX_CONTRIBUTION;

    //     uint256 activeNFTs;

    //     for (uint256 i; i < bal; ++i) {
    //         uint256 tokenId = tokenOfOwnerByIndex(msg.sender, i);

    //         if (!isNFTActive[tokenId]) {
    //             isNFTActive[tokenId] = true;
    //             ++activeNFTs;

    //             emit OnRevShareNFTActivated(msg.sender, tokenId);

    //             if (activeNFTs == tokensToActivate) break;
    //         }
    //     }
    // }

    // /*//////////////////////////////////////////////////////////////
    //                          CLAIM REVENUE
    // //////////////////////////////////////////////////////////////*/

    // function claimRevenue() external {
    //     uint256 bal;

    //     if (msg.sender == takadaoOperator) bal = MAX_SUPPLY - totalSupply();
    //     else bal = balanceOf(msg.sender);

    //     require(bal > 0, RevShareModule__NotNFTOwner());

    //     // Update the revenues
    //     _updateRevenue(msg.sender);

    //     uint256 revenue = revenues[msg.sender];

    //     require(revenue > 0, RevShareModule__NoRevenueToClaim());

    //     revenues[msg.sender] = 0;
    //     usdc.safeTransfer(msg.sender, revenue);

    //     emit OnRevenueClaimed(msg.sender, revenue);
    // }

    // function getRevenuePerNFT() external view returns (uint256) {
    //     return _revenuePerNFT();
    // }

    // /**
    //  * @notice How much a user have earned in total
    //  */
    // function getRevenueEarnedByUser(address user) external view returns (uint256) {
    //     return _revenueEarnedByUser(user);
    // }

    // /*//////////////////////////////////////////////////////////////
    //                        INTERNAL FUNCTIONS
    // //////////////////////////////////////////////////////////////*/

    function _updateRevenue(address _user) internal {
        revenuePerNFTOwned = _revenuePerNFT();
        lastUpdatedTimestamp = block.timestamp;

        revenues[_user] = _revenueEarnedByUser(_user);
        userRevenuePerNFTPaid[_user] = revenuePerNFTOwned;
    }

    function _revenuePerNFT() internal view returns (uint256) {
        return (revenuePerNFTOwned +
            ((revenueRate * (block.timestamp - lastUpdatedTimestamp) * DECIMAL_CORRECTION) /
                MAX_SUPPLY));
    }

    function _revenueEarnedByUser(address _user) internal view returns (uint256) {
        uint256 bal;

        if (msg.sender == takadaoOperator) bal = MAX_SUPPLY - totalSupply();
        else bal = balanceOf(msg.sender);

        uint256 activeNFTs;

        if (msg.sender == takadaoOperator) {
            activeNFTs = bal;
        } else {
            for (uint256 i; i < bal; ++i) {
                uint256 tokenId = tokenOfOwnerByIndex(msg.sender, i);

                if (isNFTActive[tokenId]) ++activeNFTs;
            }
        }

        return (((activeNFTs * (_revenuePerNFT() - userRevenuePerNFTPaid[_user])) /
            DECIMAL_CORRECTION) + revenues[_user]);
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

    /// @notice Needed override
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(ModuleConstants.TAKADAO_OPERATOR) {}
}
