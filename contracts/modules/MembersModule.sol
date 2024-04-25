//SPDX-License-Identifier: GPL-3.0

/**
 * @title MembersModule
 * @author Maikel Ordaz
 * @dev Users communicate with this module to become members of the DAO. It contains member management
 *      functionality such as modifying or canceling the policy, updates BM and BMA, remove non active
 *      members, calculate surplus
 * @dev Upgradeable contract with UUPS pattern
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasurePool} from "../interfaces/ITakasurePool.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

import {Fund, Member, MemberState} from "../types/TakasureTypes.sol";

pragma solidity 0.8.25;

contract MembersModule is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    IERC20 private contributionToken;
    ITakasurePool private takasurePool;

    // ? Question: pool? fund? which one should we use?
    // ! Note: decide naming convention. Or did I missed it in the documentation?, think is better "pool"
    Fund private pool;

    uint256 private wakalaFee; // ? wakala? wakalah? different names in the documentation
    uint256 private constant MINIMUM_THRESHOLD = 25e6; // 25 USDC // 6 decimals
    uint256 public memberIdCounter;

    mapping(uint256 memberIdCounter => Member) private idToMember;

    error MembersModule__ZeroAddress();
    error MembersModule__ContributionBelowMinimumThreshold();
    error MembersModule__TransferFailed();
    error MembersModule__MintFailed();

    event MemberJoined(
        address indexed member,
        uint256 indexed contributionAmount,
        MemberState memberState
    );

    function initialize(address _contributionToken, address _takasurePool) public initializer {
        if (_contributionToken == address(0) || _takasurePool == address(0)) {
            revert MembersModule__ZeroAddress();
        }

        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);

        contributionToken = IERC20(_contributionToken);
        takasurePool = ITakasurePool(_takasurePool);

        wakalaFee = 20; // 20%

        // Todo: For now we will initialize the pool with 0 values. For the future, we will define the parameters
        pool.dynamicReserveRatio = 0;
        pool.BMA = 0;
        pool.totalContributions = 0;
        pool.totalClaimReserve = 0;
        pool.totalFundReserve = 0;
        pool.wakalaFee = 0;
    }

    function joinPool(
        uint256 benefitMultiplier,
        uint256 contributionAmount, // 6 decimals
        uint256 membershipDuration
    ) external {
        // Todo: Check the user benefit multiplier against the oracle
        if (contributionAmount < MINIMUM_THRESHOLD) {
            revert MembersModule__ContributionBelowMinimumThreshold();
        }

        _joinPool(benefitMultiplier, contributionAmount, membershipDuration);

        bool successfullDeposit = contributionToken.transferFrom(
            msg.sender,
            address(this),
            contributionAmount
        );
        if (!successfullDeposit) {
            revert MembersModule__TransferFailed();
        }
    }

    function setNewWakalaFee(uint256 newWakalaFee) external onlyOwner {
        wakalaFee = newWakalaFee;
    }

    function setNewContributionToken(address newContributionToken) external onlyOwner {
        if (newContributionToken == address(0)) {
            revert MembersModule__ZeroAddress();
        }
        contributionToken = IERC20(newContributionToken);
    }

    function setNewTakasurePool(address newTakasurePool) external onlyOwner {
        if (newTakasurePool == address(0)) {
            revert MembersModule__ZeroAddress();
        }
        takasurePool = ITakasurePool(newTakasurePool);
    }

    function getWakalaFee() external view returns (uint256) {
        return wakalaFee;
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

    function getTakasurePoolAddress() external view returns (address) {
        return address(takasurePool);
    }

    function getContributionTokenAddress() external view returns (address contributionToken_) {
        contributionToken_ = address(contributionToken);
    }

    function _joinPool(
        uint256 _benefitMultiplier,
        uint256 _contributionAmount, // 6 decimals
        uint256 _membershipDuration
    ) internal {
        uint256 wakalaAmount = (_contributionAmount * wakalaFee) / 100;

        // Todo: re-calculate the Dynamic Reserve Ratio, BMA, and DAO Surplus

        memberIdCounter++;

        // Create new member
        Member memory newMember = Member({
            memberId: memberIdCounter, // Todo: Discuss: where to get this id from?
            membershipDuration: _membershipDuration,
            membershipStartTime: block.timestamp,
            netContribution: _contributionAmount,
            wallet: msg.sender,
            memberState: MemberState.Active,
            surplus: 0 // Todo
        });

        pool.members[msg.sender] = newMember;
        pool.totalContributions += _contributionAmount;
        pool.wakalaFee += wakalaAmount;

        idToMember[memberIdCounter] = newMember;

        uint256 amountToMint = _contributionAmount * 10 ** 12; // 6 decimals to 18 decimals

        bool minted = takasurePool.mint(msg.sender, amountToMint);
        if (!minted) {
            revert MembersModule__MintFailed();
        }

        emit MemberJoined(msg.sender, _contributionAmount, idToMember[memberIdCounter].memberState);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
