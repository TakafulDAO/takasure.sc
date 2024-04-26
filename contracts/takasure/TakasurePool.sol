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

import {Fund, Member, MemberState} from "../types/TakasureTypes.sol";

pragma solidity 0.8.25;

contract TakasurePool is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    IERC20 private contributionToken;
    ITakaToken private takaToken;

    // ? Question: pool? fund? which one should we use?
    // ! Note: decide naming convention. Or did I missed it in the documentation?, think is better "pool"
    Fund private pool;

    uint256 private constant MINIMUM_THRESHOLD = 25e6; // 25 USDC // 6 decimals
    uint256 public memberIdCounter;
    address private wakalaClaimAddress; // The DAO operators address // todo: discuss, this should be the owner? immutable?

    mapping(uint256 memberIdCounter => Member) private idToMember;

    error TakasurePool__ZeroAddress();
    error TakasurePool__ContributionBelowMinimumThreshold();
    error TakasurePool__ContributionTransferFailed();
    error TakasurePool__FeeTransferFailed();
    error TakasurePool__MintFailed();

    event MemberJoined(
        address indexed member,
        uint256 indexed contributionAmount,
        MemberState memberState
    );

    function initialize(
        address _contributionToken,
        address _takaToken,
        address _wakalaClaimAddress
    ) public initializer {
        if (_contributionToken == address(0) || _takaToken == address(0)) {
            revert TakasurePool__ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);

        contributionToken = IERC20(_contributionToken);
        takaToken = ITakaToken(_takaToken);
        wakalaClaimAddress = _wakalaClaimAddress;

        pool.dynamicReserveRatio = 40; // 40% Default
        pool.BMA = 1; // Default
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
        // Todo: Check the user benefit multiplier against the oracle
        if (contributionAmount < MINIMUM_THRESHOLD) {
            revert TakasurePool__ContributionBelowMinimumThreshold();
        }

        _joinPool(benefitMultiplier, contributionAmount, membershipDuration);

        uint256 wakalaAmount = (contributionAmount * pool.wakalaFee) / 100;

        // Transfer the contribution to the pool
        bool successfullDeposit = contributionToken.transferFrom(
            msg.sender,
            address(this),
            contributionAmount - wakalaAmount
        );
        if (!successfullDeposit) {
            revert TakasurePool__ContributionTransferFailed();
        }

        // Transfer the wakala fee to the DAO
        bool succesfullFeeDeposit = contributionToken.transferFrom(
            msg.sender,
            wakalaClaimAddress,
            wakalaAmount
        );

        if (!succesfullFeeDeposit) {
            revert TakasurePool__FeeTransferFailed();
        }
    }

    function setNewWakalaFee(uint256 newWakalaFee) external onlyOwner {
        pool.wakalaFee = newWakalaFee;
    }

    function setNewContributionToken(address newContributionToken) external onlyOwner {
        if (newContributionToken == address(0)) {
            revert TakasurePool__ZeroAddress();
        }
        contributionToken = IERC20(newContributionToken);
    }

    function setNewWakalaClaimAddress(address newWakalaClaimAddress) external onlyOwner {
        if (newWakalaClaimAddress == address(0)) {
            revert TakasurePool__ZeroAddress();
        }
        wakalaClaimAddress = newWakalaClaimAddress;
    }

    function getWakalaFee() external view returns (uint256) {
        return pool.wakalaFee;
    }

    function getMinimumThreshold() external pure returns (uint256) {
        return MINIMUM_THRESHOLD;
    }

    function getPoolValues()
        external
        view
        returns (
            uint256 dynamicReserveRatio_,
            uint256 BMA_,
            uint256 totalContributions_,
            uint256 totalClaimReserve_,
            uint256 totalFundReserve_,
            uint256 wakalaFee_
        )
    {
        dynamicReserveRatio_ = pool.dynamicReserveRatio;
        BMA_ = pool.BMA;
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

    function _joinPool(
        uint256 _benefitMultiplier,
        uint256 _contributionAmount, // 6 decimals
        uint256 _membershipDuration
    ) internal {
        // Todo: re-calculate the Dynamic Reserve Ratio, BMA, and DAO Surplus

        memberIdCounter++;

        // Create new member
        Member memory newMember = Member({
            memberId: memberIdCounter,
            benefitMultiplier: _benefitMultiplier,
            membershipDuration: _membershipDuration,
            membershipStartTime: block.timestamp,
            netContribution: _contributionAmount,
            wallet: msg.sender,
            memberState: MemberState.Active,
            surplus: 0 // Todo
        });

        pool.members[msg.sender] = newMember;
        pool.totalContributions += _contributionAmount;

        idToMember[memberIdCounter] = newMember;

        uint256 amountToMint = _contributionAmount * 10 ** 12; // 6 decimals to 18 decimals

        bool minted = takaToken.mint(msg.sender, amountToMint);
        if (!minted) {
            revert TakasurePool__MintFailed();
        }

        emit MemberJoined(msg.sender, _contributionAmount, idToMember[memberIdCounter].memberState);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
