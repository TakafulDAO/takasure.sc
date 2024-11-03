// SPDX-License-Identifier: GPL-3.0

/**
 * @title ReferralGateway
 * @author Maikel Ordaz
 * @dev This contract will manage all the functionalities related to the referral system and pre-joins
 *      to the LifeDAO protocol
 * @dev Upgradeable contract with UUPS pattern
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITakasurePool} from "contracts/interfaces/ITakasurePool.sol";
import {IBenefitMultiplierConsumer} from "contracts/interfaces/IBenefitMultiplierConsumer.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

pragma solidity 0.8.28;

/// @custom:oz-upgrades-from contracts/version_previous_contracts/ReferralGatewayV1.sol:ReferralGatewayV1
contract ReferralGateway is
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable
{
    using SafeERC20 for IERC20;

    IERC20 public usdc;
    IBenefitMultiplierConsumer private bmConsumer;

    address private operator;
    // uint256 private referralReserveBalance;

    mapping(address parent => mapping(address child => uint256 rewards))
        public parentRewardsByChild;
    mapping(address parent => mapping(uint256 layer => uint256 rewards))
        public parentRewardsByLayer;
    mapping(address member => mapping(string tDAOName => PrepaidMember)) public prepaidMembers;
    mapping(string tDAOName => tDAO DAOData) private nameToDAOData;
    mapping(address member => bool) public isMemberKYCed;
    mapping(address child => address parent) public childToParent;

    struct PrepaidMember {
        string tDAOName;
        address member;
        uint256 contributionBeforeFee;
        uint256 contributionAfterFee;
        uint256 finalFee; // Fee after all the discounts and rewards
        uint256 discount;
    }

    struct tDAO {
        string name;
        bool preJoinEnabled;
        bool referralDiscount;
        address DAOAdmin; // The one that can modify the DAO settings
        address DAOAddress; // To be assigned when the tDAO is deployed
        uint256 launchDate; // In seconds. An estimated launch date of the DAO
        uint256 objectiveAmount; // In USDC, six decimals
        uint256 currentAmount; // In USDC, six decimals
        uint256 collectedFees; // Fees collected after deduct, discounts, referral reserve and repool amounts. In USDC, six decimals
        address rePoolAddress; // To be assigned when the tDAO is deployed
        uint256 toRepool; // In USDC, six decimals
        uint256 referralReserve; // In USDC, six decimals
    }

    /*//////////////////////////////////////////////////////////////
                              FIXED RATIOS
    //////////////////////////////////////////////////////////////*/

    uint8 public constant SERVICE_FEE_RATIO = 27;
    uint256 public constant CONTRIBUTION_PREJOIN_DISCOUNT_RATIO = 10; // 10% of contribution deducted from fee
    uint256 public constant REFERRAL_DISCOUNT_RATIO = 5; // 5% of contribution deducted from contribution
    uint256 public constant REFERRAL_RESERVE = 5; // 5% of contribution TO Referral Reserve
    uint256 public constant REPOOL_FEE_RATIO = 2; // 2% of contribution deducted from fee
    uint256 private constant MINIMUM_CONTRIBUTION = 25e6; // 25 USDC
    uint256 private constant MAXIMUM_CONTRIBUTION = 250e6; // 250 USDC

    /*//////////////////////////////////////////////////////////////
                            REWARDS RELATED
    //////////////////////////////////////////////////////////////*/

    int256 private constant MAX_TIER = 4;
    int256 private constant A = -3_125;
    int256 private constant B = 30_500;
    int256 private constant C = -99_625;
    int256 private constant D = 112_250;
    uint256 private constant DECIMAL_CORRECTION = 10_000;

    /*//////////////////////////////////////////////////////////////
                                 ROLES
    //////////////////////////////////////////////////////////////*/

    bytes32 private constant OPERATOR = keccak256("OPERATOR");
    bytes32 public constant KYC_PROVIDER = keccak256("KYC_PROVIDER");
    bytes32 private constant COFOUNDER_OF_CHANGE = keccak256("COFOUNDER_OF_CHANGE");

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnNewCofounderOfChange(address indexed cofounderOfChange);
    event OnPrepayment(address indexed parent, address indexed child, uint256 indexed contribution);
    event OnParentRewarded(
        address indexed parent,
        uint256 indexed layer,
        address indexed child,
        uint256 reward
    );
    event OnChildKYCVerified(address indexed child);
    event OnBenefitMultiplierConsumerChanged(
        address indexed newBenefitMultiplierConsumer,
        address indexed oldBenefitMultiplierConsumer
    );
    event OnRefund(string indexed tDAOName, address indexed member, uint256 indexed amount);

    error ReferralGateway__ZeroAddress();
    error ReferralGateway__onlyDAOAdmin();
    error ReferralGateway__MustHaveName();
    error ReferralGateway__InvalidLaunchDate();
    error ReferralGateway__AlreadyExists();
    error ReferralGateway__DAOAlreadyLaunched();
    error ReferralGateway__ZeroAmount();
    error ReferralGateway__ContributionOutOfRange();
    error ReferralGateway__AlreadyMember();
    error ReferralGateway__MemberAlreadyKYCed();
    error ReferralGateway__HasNotPaid();
    error ReferralGateway__NotKYCed();
    error ReferralGateway__tDAONotReadyYet();

    modifier notZeroAddress(address _address) {
        require(_address != address(0), ReferralGateway__ZeroAddress());
        _;
    }

    modifier onlyDAOAdmin(string calldata tDAOName) {
        require(nameToDAOData[tDAOName].DAOAdmin == msg.sender, ReferralGateway__onlyDAOAdmin());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _operator,
        address _KYCProvider,
        address _usdcAddress,
        address _benefitMultiplierConsumer
    ) external notZeroAddress(_operator) notZeroAddress(_usdcAddress) initializer {
        __UUPSUpgradeable_init();
        __AccessControl_init();
        __ReentrancyGuardTransient_init();
        _grantRole(DEFAULT_ADMIN_ROLE, _operator);
        _grantRole(OPERATOR, _operator);
        _grantRole(KYC_PROVIDER, _KYCProvider);

        bmConsumer = IBenefitMultiplierConsumer(_benefitMultiplierConsumer);

        operator = _operator;
        usdc = IERC20(_usdcAddress);
    }

    /**
     * @notice Register a Cofounder of Change
     * @param cofounderOfChange The address to register as cofounderOfChange
     * @dev Only the OPERATOR can register an cofounderOfChange
     */
    function registerCofounderOfChange(
        address cofounderOfChange
    ) external notZeroAddress(cofounderOfChange) onlyRole(OPERATOR) {
        _grantRole(COFOUNDER_OF_CHANGE, cofounderOfChange);

        emit OnNewCofounderOfChange(cofounderOfChange);
    }

    /*//////////////////////////////////////////////////////////////
                               DAO ADMIN
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Create a new DAO
     * @param DAOName The name of the DAO
     * @param isPreJoinEnabled The pre-join status of the DAO
     * @param isReferralDiscountEnabled The referral discount status of the DAO
     * @param launchDate An estimated launch date of the DAO
     * @param objectiveAmount The objective amount of the DAO
     * @dev The launch date must be in seconds
     * @dev The launch date can be 0, if the DAO is already launched or the launch date is not defined
     * @dev The objective amount must be in USDC, six decimals
     * @dev The objective amount can be 0, if the DAO is already launched or the objective amount is not defined
     */
    function createDAO(
        string calldata DAOName,
        bool isPreJoinEnabled,
        bool isReferralDiscountEnabled,
        uint256 launchDate,
        uint256 objectiveAmount
    ) external {
        require(bytes(DAOName).length != 0, ReferralGateway__MustHaveName());
        require(
            !(Strings.equal(nameToDAOData[DAOName].name, DAOName)),
            ReferralGateway__AlreadyExists()
        );
        require(launchDate > block.timestamp, ReferralGateway__InvalidLaunchDate());

        // Create the new DAO
        tDAO memory DAO = tDAO({
            name: DAOName, // To be used as a key
            preJoinEnabled: isPreJoinEnabled,
            referralDiscount: isReferralDiscountEnabled,
            DAOAdmin: msg.sender,
            DAOAddress: address(0), // To be assigned when the tDAO is deployed
            rePoolAddress: address(0), // To be assigned when the tDAO is deployed
            launchDate: launchDate, // in seconds
            objectiveAmount: objectiveAmount,
            currentAmount: 0,
            collectedFees: 0,
            toRepool: 0,
            referralReserve: 0
        });

        // Update the necessary mappings
        nameToDAOData[DAO.name] = DAO;
    }

    /**
     * @notice Update the DAO estimated launch date
     */
    function updateLaunchDate(
        string calldata tDAOName,
        uint256 launchDate
    ) external onlyDAOAdmin(tDAOName) {
        require(
            nameToDAOData[tDAOName].DAOAddress == address(0),
            ReferralGateway__DAOAlreadyLaunched()
        );
        nameToDAOData[tDAOName].launchDate = launchDate;
    }

    /**
     * @notice Method to be called after a tDAO is deployed
     * @param tDAOName The name of the tDAO
     * @param tDAOAddress The address of the tDAO
     * @param isReferralDiscountEnabled The referral discount status of the DAO
     * @dev Only the DAOAdmin can call this method, the DAOAdmin is the one that created the DAO and must have
     *      the role of DAO_MULTISIG in the DAO
     * @dev The tDAOAddress must be different from 0
     * @dev It will disable the preJoinEnabled status of the DAO
     */
    function launchDAO(
        string calldata tDAOName,
        address tDAOAddress,
        bool isReferralDiscountEnabled
    ) external onlyDAOAdmin(tDAOName) notZeroAddress(tDAOAddress) {
        require(
            ITakasurePool(tDAOAddress).hasRole(keccak256("DAO_MULTISIG"), msg.sender),
            ReferralGateway__onlyDAOAdmin()
        );
        require(
            nameToDAOData[tDAOName].DAOAddress == address(0),
            ReferralGateway__DAOAlreadyLaunched()
        );

        nameToDAOData[tDAOName].preJoinEnabled = false;
        nameToDAOData[tDAOName].referralDiscount = isReferralDiscountEnabled;
        nameToDAOData[tDAOName].DAOAddress = tDAOAddress;
        nameToDAOData[tDAOName].launchDate = block.timestamp;
    }

    /**
     * @notice Switch the referralDiscount status of a DAO
     */
    function switchReferralDiscount(string calldata tDAOName) external onlyDAOAdmin(tDAOName) {
        nameToDAOData[tDAOName].referralDiscount = !nameToDAOData[tDAOName].referralDiscount;
    }

    /**
     * @notice Assign a rePool address to a tDAO name
     * @param tDAOName The name of the tDAO
     * @param rePoolAddress The address of the rePool
     */
    function enableRepool(
        string calldata tDAOName,
        address rePoolAddress
    ) external notZeroAddress(rePoolAddress) onlyDAOAdmin(tDAOName) {
        require(
            nameToDAOData[tDAOName].DAOAddress != address(0),
            ReferralGateway__tDAONotReadyYet()
        );
        nameToDAOData[tDAOName].rePoolAddress = rePoolAddress;
    }

    function transferToRepool(string calldata tDAOName) external onlyDAOAdmin(tDAOName) {
        tDAO memory DAO = nameToDAOData[tDAOName];
        require(DAO.rePoolAddress != address(0), ReferralGateway__ZeroAddress());
        require(DAO.toRepool > 0, ReferralGateway__ZeroAmount());

        uint256 amount = DAO.toRepool;
        address rePoolAddress = DAO.rePoolAddress;

        nameToDAOData[tDAOName].toRepool = 0;

        usdc.safeTransfer(rePoolAddress, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 JOINS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Pay a contribution to a DAO
     * @param contribution The amount of the contribution. In USDC six decimals
     * @param tDAOName The name of the DAO
     * @param parent The address of the parent. Optional
     * @dev The contribution must be between MINIMUM_CONTRIBUTION and MAXIMUM_CONTRIBUTION
     * @dev The function will create a prepaid member object with the contribution data if
     *      the DAO is not deployed yet, otherwise it will call the DAO to join
     * @dev It will apply the discounts and rewards if the DAO has the features enabled
     */
    function payContribution(
        uint256 contribution,
        string calldata tDAOName,
        address parent
    ) external returns (uint256 finalFee, uint256 discount) {
        tDAO memory DAO = nameToDAOData[tDAOName];
        require(
            contribution >= MINIMUM_CONTRIBUTION && contribution <= MAXIMUM_CONTRIBUTION,
            ReferralGateway__ContributionOutOfRange()
        );

        uint256 fee = (contribution * SERVICE_FEE_RATIO) / 100;
        finalFee = fee;
        // If the DAO pre join is enabled it means the DAO is not deployed yet
        if (DAO.preJoinEnabled) {
            // The prepaid member object is created inside this if statement only
            // We check if the member already exists
            require(
                prepaidMembers[msg.sender][tDAOName].contributionBeforeFee == 0,
                ReferralGateway__AlreadyMember()
            );

            uint256 amountToTransfer = contribution;

            // It will get a discount as a pre-joiner
            discount += (contribution * CONTRIBUTION_PREJOIN_DISCOUNT_RATIO) / 100;
            amountToTransfer -= discount;
            finalFee -= discount;

            if (DAO.referralDiscount) {
                uint256 toReferralReserve = (contribution * REFERRAL_RESERVE) / 100;
                finalFee -= toReferralReserve;
                if (parent != address(0) && isMemberKYCed[parent]) {
                    uint256 referralDiscount = (contribution * REFERRAL_DISCOUNT_RATIO) / 100;
                    discount += referralDiscount;
                    amountToTransfer -= referralDiscount;
                    finalFee -= referralDiscount;

                    childToParent[msg.sender] = parent;

                    (finalFee, DAO.referralReserve) = _parentRewards(
                        msg.sender,
                        contribution,
                        DAO.referralReserve,
                        toReferralReserve,
                        finalFee
                    );
                }
            }

            uint256 rePoolFee = (contribution * REPOOL_FEE_RATIO) / 100;

            finalFee -= rePoolFee;

            nameToDAOData[tDAOName].toRepool += rePoolFee;
            nameToDAOData[tDAOName].currentAmount += amountToTransfer;
            nameToDAOData[tDAOName].collectedFees += finalFee;

            // We transfer the contribution minus the discount (if any) minus the fee
            usdc.safeTransferFrom(msg.sender, address(this), amountToTransfer);

            usdc.safeTransfer(operator, finalFee);

            PrepaidMember memory prepayer = PrepaidMember({
                tDAOName: tDAOName,
                member: msg.sender,
                contributionBeforeFee: contribution, // Input value, we need it like this for the actual join when the DAO is deployed
                contributionAfterFee: contribution - discount - fee, // Without discount, we need it like this for the actual join when the DAO is deployed
                finalFee: finalFee,
                discount: discount
            });

            prepaidMembers[msg.sender][tDAOName] = prepayer;

            // Finally, we request the benefit multiplier for the member, this to have it ready when the member joins the DAO
            _getBenefitMultiplierFromOracle(msg.sender);

            emit OnPrepayment(parent, msg.sender, contribution);
        } else {
            /**
             * Call the DAO to join
             *  TODO: This call needs to change the joinPool function to add a param for the new member
             *  TODO: To Implement call the function in the router. For V2 of this contract
             */
        }
    }

    /**
     * @notice Set the KYC status of a member
     * @param child The address of the member
     * @dev Only the KYC_PROVIDER can set the KYC status
     */
    function setKYCStatus(
        address child,
        string calldata tDAOName
    ) external notZeroAddress(child) onlyRole(KYC_PROVIDER) {
        // Initial checks
        PrepaidMember memory member = prepaidMembers[child][tDAOName];
        // Can not KYC a member that is already KYCed
        require(!isMemberKYCed[child], ReferralGateway__MemberAlreadyKYCed());

        // The member must have already pre-paid
        require(member.contributionBeforeFee != 0, ReferralGateway__HasNotPaid());

        // Update the KYC status
        isMemberKYCed[child] = true;

        address parent = childToParent[child];

        for (uint256 i; i < uint256(MAX_TIER); ++i) {
            if (parent == address(0)) break;

            uint256 layer = i + 1;

            uint256 parentReward = parentRewardsByChild[parent][child];

            parentRewardsByChild[parent][child] = 0;
            parentRewardsByLayer[parent][layer] = 0;
            usdc.safeTransfer(parent, parentReward);

            emit OnParentRewarded(parent, layer, child, parentReward);

            // We update the parent address to check the next parent
            parent = childToParent[parent];
        }

        emit OnChildKYCVerified(child);
    }

    /**
     * @notice Join a tDAO
     * @param newMember The address of the new member
     * @dev The member must be KYCed
     * @dev The member must have a parent
     * @dev The member must have a tDAO assigned
     */
    function joinDAO(address newMember, string calldata tDAOName) external nonReentrant {
        // Initial checks
        require(isMemberKYCed[newMember], ReferralGateway__NotKYCed());

        PrepaidMember memory prepaidMember = prepaidMembers[newMember][tDAOName];
        tDAO memory DAO = nameToDAOData[prepaidMember.tDAOName];

        require(
            DAO.DAOAddress != address(0) && DAO.launchDate <= block.timestamp,
            ReferralGateway__tDAONotReadyYet()
        );

        // Finally, we join the prepaidMember to the tDAO
        ITakasurePool(DAO.DAOAddress).prejoins(
            newMember,
            prepaidMember.contributionBeforeFee,
            prepaidMember.contributionAfterFee
        );

        usdc.safeTransfer(DAO.DAOAddress, prepaidMember.contributionAfterFee);
    }

    /*//////////////////////////////////////////////////////////////
                                REFUNDS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Refund a prepaid member if the DAO is not deployed at launch date
     * @param member The address of the member
     * @param tDAOName The name of the DAO
     */
    function refundIfDAOIsNotLaunched(address member, string calldata tDAOName) external {
        tDAO memory DAO = nameToDAOData[tDAOName];

        require(
            DAO.launchDate < block.timestamp && DAO.DAOAddress == address(0),
            ReferralGateway__tDAONotReadyYet()
        );

        PrepaidMember memory prepaidMember = prepaidMembers[member][tDAOName];
        require(prepaidMember.contributionBeforeFee != 0, ReferralGateway__HasNotPaid());

        uint256 feePaid = prepaidMember.contributionBeforeFee - prepaidMember.contributionAfterFee;
        uint256 discountReceived = prepaidMember.discount;

        uint256 amountToRefund = prepaidMember.contributionBeforeFee - feePaid - discountReceived;

        prepaidMembers[member][tDAOName] = PrepaidMember({
            tDAOName: "",
            member: address(0),
            contributionBeforeFee: 0,
            contributionAfterFee: 0,
            finalFee: 0,
            discount: 0
        });
        isMemberKYCed[member] = false;

        usdc.safeTransfer(member, amountToRefund);

        emit OnRefund(tDAOName, member, amountToRefund);
    }

    /*//////////////////////////////////////////////////////////////
                                REWARDS
    //////////////////////////////////////////////////////////////*/

    function withdrawRewards() external nonReentrant {
        for (int256 i; i < MAX_TIER; ++i) {
            uint256 layer = uint256(i + 1);
            uint256 reward = parentRewardsByLayer[msg.sender][layer];
            parentRewardsByLayer[msg.sender][layer] = 0;
            usdc.safeTransfer(msg.sender, reward);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                SETTERS
    //////////////////////////////////////////////////////////////*/

    function setUsdcAddress(address _usdcAddress) external onlyRole(OPERATOR) {
        usdc = IERC20(_usdcAddress);
    }

    function setNewBenefitMultiplierConsumer(
        address newBenefitMultiplierConsumer
    ) external onlyRole(OPERATOR) notZeroAddress(newBenefitMultiplierConsumer) {
        address oldBenefitMultiplierConsumer = address(bmConsumer);
        bmConsumer = IBenefitMultiplierConsumer(newBenefitMultiplierConsumer);

        emit OnBenefitMultiplierConsumerChanged(
            newBenefitMultiplierConsumer,
            oldBenefitMultiplierConsumer
        );
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function getDAOData(string calldata tDAOName) external view returns (tDAO memory) {
        return nameToDAOData[tDAOName];
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _getBenefitMultiplierFromOracle(address _member) internal {
        string memory memberAddressToString = Strings.toHexString(uint256(uint160(_member)), 20);
        string[] memory args = new string[](1);
        args[0] = memberAddressToString;
        bmConsumer.sendRequest(args);
    }

    function _parentRewards(
        address _initialChildToCheck,
        uint256 _contribution,
        uint256 _currentReferralReserve,
        uint256 _toReferralReserve,
        uint256 _currentFee
    ) internal returns (uint256, uint256) {
        address currentChildToCheck = _initialChildToCheck;
        uint256 newReferralReserveBalance = _currentReferralReserve + _toReferralReserve;
        uint256 parentRewardsAccumulated;

        for (int256 i; i < MAX_TIER; ++i) {
            if (
                childToParent[currentChildToCheck] == address(0) ||
                !isMemberKYCed[childToParent[currentChildToCheck]]
            ) {
                break;
            }

            uint256 parentReward = (_contribution * _referralRewardRatioByLayer(i + 1)) /
                (100 * DECIMAL_CORRECTION);
            parentRewardsByChild[childToParent[currentChildToCheck]][msg.sender] = parentReward;
            parentRewardsByLayer[childToParent[currentChildToCheck]][
                uint256(i + 1)
            ] += parentReward;

            parentRewardsAccumulated += parentReward;

            currentChildToCheck = childToParent[currentChildToCheck];
        }

        if (newReferralReserveBalance > parentRewardsAccumulated) {
            newReferralReserveBalance -= parentRewardsAccumulated;
        } else {
            uint256 rewardFromReserve = parentRewardsAccumulated - newReferralReserveBalance;
            _currentFee -= rewardFromReserve;
            newReferralReserveBalance = 0;
        }

        return (_currentFee, newReferralReserveBalance);
    }

    /**
     * @notice This function calculates the referral reward ratio based on the layer
     * @param _layer The layer of the referral
     * @return referralRewardRatio_ The referral reward ratio
     * @dev Max Layer = 4
     * @dev The formula is y = Ax^3 + Bx^2 + Cx + D
     *      y = reward ratio, x = layer, A = -3_125, B = 30_500, C = -99_625, D = 112_250
     *      The original values are layer 1 = 4%, layer 2 = 1%, layer 3 = 0.35%, layer 4 = 0.175%
     *      But this values where multiplied by 10_000 to avoid decimals in the formula so the values are
     *      layer 1 = 40_000, layer 2 = 10_000, layer 3 = 3_500, layer 4 = 1_750
     */
    function _referralRewardRatioByLayer(
        int256 _layer
    ) internal pure returns (uint256 referralRewardRatio_) {
        assembly {
            let layerSquare := mul(_layer, _layer) // x^2
            let layerCube := mul(_layer, layerSquare) // x^3

            // y = Ax^3 + Bx^2 + Cx + D
            referralRewardRatio_ := add(
                add(add(mul(A, layerCube), mul(B, layerSquare)), mul(C, _layer)),
                D
            )
        }
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(OPERATOR) {}
}
