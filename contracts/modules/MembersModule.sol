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

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {TakaToken} from "../token/TakaToken.sol";

import {Fund, Member, MemberState} from "../types/TakasureTypes.sol";

pragma solidity 0.8.24;

contract MembersModule is Initializable, UUPSUpgradeable, OwnableUpgradeable {
    IERC20 private contributionToken;
    TakaToken private takaToken;

    uint256 private wakalaFee; // ? wakala? wakalah? different names in the documentation
    uint256 private constant MINIMUM_THRESHOLD = 25e6; // 25 USDC
    uint256 public fundIdCounter;
    uint256 public memberIdCounter;

    mapping(uint256 fundIdCounter => Fund) private idToFund;
    mapping(uint256 memberIdCounter => Member) private idToMember;

    error MembersModule__ContributionBelowMinimumThreshold();
    error MembersModule__TransferFailed();
    error MembersModule__MintFailed();

    event MemberJoined(
        uint256 indexed joinedFundId,
        address indexed member,
        uint256 indexed contributionAmount,
        MemberState memberState
    );
    event PoolCreated(uint256 indexed fundId);

    function initialize(address _contributionToken, address _takaToken) public initializer {
        __UUPSUpgradeable_init();
        __Ownable_init(msg.sender);

        contributionToken = IERC20(_contributionToken);
        takaToken = TakaToken(_takaToken);

        wakalaFee = 20; // 20%
    }

    function createPool() external {
        fundIdCounter++;

        // Todo: Calculate some of this at the begining?

        idToFund[fundIdCounter].dynamicReserveRatio = 0;
        idToFund[fundIdCounter].BMA = 0;
        idToFund[fundIdCounter].totalContributions = 0;
        idToFund[fundIdCounter].totalClaimReserve = 0;
        idToFund[fundIdCounter].totalFundReserve = 0;
        idToFund[fundIdCounter].wakalaFee = 0;

        emit PoolCreated(fundIdCounter);
    }

    function joinPool(
        uint256 fundIdToJoin,
        uint256 benefitMultiplier,
        uint256 contributionAmount,
        uint256 membershipDuration
    ) external {
        // Todo: Check the user benefit multiplier against the oracle
        if (contributionAmount < MINIMUM_THRESHOLD) {
            revert MembersModule__ContributionBelowMinimumThreshold();
        }

        bool successfullDeposit = contributionToken.transferFrom(
            msg.sender,
            address(this),
            contributionAmount
        );
        if (!successfullDeposit) {
            revert MembersModule__TransferFailed();
        }

        uint256 wakalaAmount = (contributionAmount * wakalaFee) / 100;

        bool successfullMint = takaToken.mint(msg.sender, contributionAmount); // ? or contributionAmount?
        if (!successfullMint) {
            revert MembersModule__MintFailed();
        }

        // Todo: re-calculate the Dynamic Reserve Ratio, BMA, and DAO Surplus

        memberIdCounter++;

        // Create new member
        Member memory newMember = Member({
            memberId: memberIdCounter, // Todo: Discuss: where to get this id from?
            membershipDuration: membershipDuration,
            membershipStartTime: block.timestamp,
            netContribution: contributionAmount,
            wallet: msg.sender,
            memberState: MemberState.Active,
            surplus: 0 // Todo
        });

        idToFund[fundIdToJoin].members[msg.sender] = newMember;
        idToFund[fundIdToJoin].totalContributions += contributionAmount;
        idToFund[fundIdToJoin].wakalaFee += wakalaAmount;

        emit MemberJoined(
            fundIdToJoin,
            msg.sender,
            contributionAmount,
            idToMember[memberIdCounter].memberState
        );
    }

    function setNewWakalaFee(uint256 newWakalaFee) external onlyOwner {
        wakalaFee = newWakalaFee;
    }

    function getWakalaFee() external view returns (uint256) {
        return wakalaFee;
    }

    function getMinimumThreshold() external pure returns (uint256) {
        return MINIMUM_THRESHOLD;
    }

    function getFundFromId(
        uint256 fundId
    )
        external
        view
        returns (
            uint256 dynamicReserveRatio,
            uint256 BMA,
            uint256 totalContributions,
            uint256 totalClaimReserve,
            uint256 totalFundReserve,
            uint256 wakalaFee_
        )
    {
        dynamicReserveRatio = idToFund[fundId].dynamicReserveRatio;
        BMA = idToFund[fundId].BMA;
        totalContributions = idToFund[fundId].totalContributions;
        totalClaimReserve = idToFund[fundId].totalClaimReserve;
        totalFundReserve = idToFund[fundId].totalFundReserve;
        wakalaFee_ = idToFund[fundId].wakalaFee;
    }

    function getMemberFromId(uint256 memberId) external view returns (Member memory) {
        return idToMember[memberId];
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
