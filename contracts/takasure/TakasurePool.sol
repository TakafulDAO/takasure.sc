//SPDX-License-Identifier: GPL-3.0

/**
 * @title TakasurePool
 * @author Maikel Ordaz
 * @dev Users communicate with this module to become members of the DAO. It contains member management
 *      functionality such as modifying or canceling the policy, updates BM and BMA, remove non active
 *      members, calculate surplus
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakaToken} from "../interfaces/ITakaToken.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Fund, Member, MemberState, KYC} from "../types/TakasureTypes.sol";

pragma solidity 0.8.25;

contract TakasurePool is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    IERC20 private contributionToken;
    ITakaToken private takaToken;

    Fund private pool;

    uint256 private constant DECIMALS_PRECISION = 1e12;
    uint256 private constant MINIMUM_MEMBERSHIP_DURATION = 5 * (365 days); // 5 year

    bool private allowCustomDuration; // while false, the membership duration is fixed to 5 years

    uint256 public minimumThreshold;
    uint256 public memberIdCounter;
    address private wakalaClaimAddress; // The DAO operators address // todo: discuss, this should be the owner? immutable?

    mapping(uint256 memberIdCounter => Member) private idToMember;
    mapping(address memberAddress => KYC) private memberKYC; // Todo: Implement KYC correctly in the future

    event MemberJoined(address indexed member, uint256 indexed contributionAmount, KYC indexed kyc);

    error TakasurePool__ZeroAddress();
    error TakasurePool__ContributionBelowMinimumThreshold();
    error TakasurePool__ContributionTransferFailed();
    error TakasurePool__FeeTransferFailed();
    error TakasurePool__MintFailed();

    modifier notZeroAddress(address _address) {
        if (_address == address(0)) {
            revert TakasurePool__ZeroAddress();
        }
        _;
    }

    function initialize(
        address _contributionToken,
        address _takaToken,
        address _wakalaClaimAddress
    )
        external
        initializer
        notZeroAddress(_contributionToken)
        notZeroAddress(_takaToken)
        notZeroAddress(_wakalaClaimAddress)
    {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);

        contributionToken = IERC20(_contributionToken);
        takaToken = ITakaToken(_takaToken);
        wakalaClaimAddress = _wakalaClaimAddress;

        minimumThreshold = 25e6; // 25 USDC // 6 decimals
        allowCustomDuration = false;

        pool.dynamicReserveRatio = 40; // 40% Default
        pool.benefitMultiplierAdjuster = 1; // Default
        pool.totalContributions = 0;
        pool.totalClaimReserve = 0;
        pool.totalFundReserve = 0;
        pool.wakalaFee = 20; // 20% of the contribution amount. Default
    }

    function joinPool(
        uint256 benefitMultiplier,
        uint256 contributionAmount, // 6 decimals
        uint256 membershipDuration
    ) external {
        // Todo: Check the user benefit multiplier against the oracle.
        if (contributionAmount < minimumThreshold) {
            revert TakasurePool__ContributionBelowMinimumThreshold();
        }

        // Todo: re-calculate the Dynamic Reserve Ratio, BMA, and DAO Surplus.

        // Create new member
        memberIdCounter++;

        uint256 userMembershipDuration;
        uint256 userCurrentNetContribution = idToMember[memberIdCounter].netContribution;

        if (allowCustomDuration) {
            userMembershipDuration = membershipDuration;
        } else {
            userMembershipDuration = MINIMUM_MEMBERSHIP_DURATION;
        }

        Member memory newMember = Member({
            memberId: memberIdCounter,
            benefitMultiplier: benefitMultiplier,
            membershipDuration: userMembershipDuration,
            membershipStartTime: block.timestamp,
            netContribution: userCurrentNetContribution + contributionAmount,
            wallet: msg.sender,
            memberState: MemberState.Active,
            surplus: 0 // Todo
        });

        // Distribute between the claim and fund reserve
        uint256 toFundReserve = (contributionAmount * pool.dynamicReserveRatio) / 100;
        uint256 toClaimReserve = contributionAmount - toFundReserve;

        // Update the pool values
        pool.members[msg.sender] = newMember;
        pool.totalContributions += contributionAmount;
        pool.totalClaimReserve += toClaimReserve;
        pool.totalFundReserve += toFundReserve;

        // Add the member to the mapping
        idToMember[memberIdCounter] = newMember;

        uint256 mintAmount = contributionAmount * DECIMALS_PRECISION; // 6 decimals to 18 decimals
        uint256 wakalaAmount = (contributionAmount * pool.wakalaFee) / 100;
        uint256 depositAmount = contributionAmount - wakalaAmount;

        // External calls
        bool success;

        // Mint the Taka token
        success = takaToken.mint(msg.sender, mintAmount);
        if (!success) {
            revert TakasurePool__MintFailed();
        }

        // Transfer the contribution to the pool
        success = contributionToken.transferFrom(msg.sender, address(this), depositAmount);
        if (!success) {
            revert TakasurePool__ContributionTransferFailed();
        }

        // Transfer the wakala fee to the DAO
        success = contributionToken.transferFrom(msg.sender, wakalaClaimAddress, wakalaAmount);
        if (!success) {
            revert TakasurePool__FeeTransferFailed();
        }

        emit MemberJoined(msg.sender, contributionAmount, memberKYC[msg.sender]);
    }

    function setNewWakalaFee(uint256 newWakalaFee) external onlyOwner {
        pool.wakalaFee = newWakalaFee;
    }

    function setNewMinimumThreshold(uint256 newMinimumThreshold) external onlyOwner {
        minimumThreshold = newMinimumThreshold;
    }

    function setNewContributionToken(
        address newContributionToken
    ) external onlyOwner notZeroAddress(newContributionToken) {
        contributionToken = IERC20(newContributionToken);
    }

    function setNewWakalaClaimAddress(
        address newWakalaClaimAddress
    ) external onlyOwner notZeroAddress(newWakalaClaimAddress) {
        wakalaClaimAddress = newWakalaClaimAddress;
    }

    function getPoolValues()
        external
        view
        returns (
            uint256 dynamicReserveRatio_,
            uint256 benefitMultiplierAdjuster_,
            uint256 totalContributions_,
            uint256 totalClaimReserve_,
            uint256 totalFundReserve_,
            uint256 wakalaFee_
        )
    {
        dynamicReserveRatio_ = pool.dynamicReserveRatio;
        benefitMultiplierAdjuster_ = pool.benefitMultiplierAdjuster;
        totalContributions_ = pool.totalContributions;
        totalClaimReserve_ = pool.totalClaimReserve;
        totalFundReserve_ = pool.totalFundReserve;
        wakalaFee_ = pool.wakalaFee;
    }

    function getMemberFromId(uint256 memberId) external view returns (Member memory) {
        return idToMember[memberId];
    }

    function getTakaTokenAddress() external view returns (address) {
        return address(takaToken);
    }

    function getContributionTokenAddress() external view returns (address contributionToken_) {
        contributionToken_ = address(contributionToken);
    }

    function getWakalaClaimAddress() external view returns (address wakalaClaimAddress_) {
        wakalaClaimAddress_ = wakalaClaimAddress;
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
