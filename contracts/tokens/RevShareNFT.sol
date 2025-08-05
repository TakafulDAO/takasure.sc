//SPDX-License-Identifier: GPL-3.0

/**
 * @title RevShareNFT
 * @author Maikel Ordaz
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRevShareModule} from "contracts/interfaces/IRevShareModule.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable, OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardTransientUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

pragma solidity 0.8.28;

/// @custom:oz-upgrades-from contracts/version_previous_contracts/RevShareNFTV1.sol:RevShareNFTV1
contract RevShareNFT is
    Initializable,
    UUPSUpgradeable,
    Ownable2StepUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    ERC721Upgradeable
{
    using SafeERC20 for IERC20;

    IAddressManager private addressManager;

    string public baseURI; // Base URI for the NFTs

    uint256 public totalSupply; // Total supply of NFTs minted

    mapping(address pioneer => mapping(uint256 tokenId => uint256 timestamp))
        public pioneerMintedAt;

    uint256 public constant MAX_SUPPLY = 8_820;

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnAddressManagerSet(address indexed oldAddressManager, address indexed newAddressManager);
    event OnRevShareModuleSet(address indexed oldRevShareModule, address indexed newRevShareModule);
    event OnBaseURISet(string indexed oldBaseUri, string indexed newBaseURI);
    event OnRevShareNFTMinted(address indexed owner, uint256 tokenId);
    event OnBatchRevShareNFTMinted(
        address indexed newOwner,
        uint256 initialTokenId,
        uint256 lastTokenId
    );

    error RevShareNFT__NotAllowedAddress();
    error RevShareNFT__MaxSupplyReached();
    error RevShareNFT__BatchMintMoreThanOne();
    error RevShareNFT__NotEnoughBalance();
    error RevShareNFT__RevShareModuleNotSetUp();

    modifier mintChecks(address pioneer) {
        AddressAndStates._notZeroAddress(pioneer);
        require(pioneer != address(this), RevShareNFT__NotAllowedAddress());
        require(totalSupply < MAX_SUPPLY, RevShareNFT__MaxSupplyReached());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(string memory _baseURI) external initializer {
        __UUPSUpgradeable_init();
        __Ownable2Step_init();
        __Ownable_init(msg.sender);
        __ReentrancyGuardTransient_init();
        __ERC721_init("RevShareNFT", "RSNFT");

        baseURI = _baseURI;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    function setAddressManager(address _addressManager) external onlyOwner {
        AddressAndStates._notZeroAddress(_addressManager);

        address oldAddressManager = address(addressManager);
        addressManager = IAddressManager(_addressManager);

        emit OnAddressManagerSet(oldAddressManager, _addressManager);
    }

    function setBaseURI(string calldata _newBaseURI) external onlyOwner {
        string memory oldBaseURI = baseURI;
        baseURI = _newBaseURI;
        emit OnBaseURISet(oldBaseURI, _newBaseURI);
    }

    /*//////////////////////////////////////////////////////////////
                                  MINT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mint single token to a user
     * @param pioneer The address of the member to mint a single NFT. This is only used for SINGLE_MINT
     * @dev Only callable by someone with owner
     */
    function mint(address pioneer) external onlyOwner mintChecks(pioneer) {
        uint256 tokenId = totalSupply;
        ++totalSupply;

        // Update the revenues if the contract is set up to do so
        bool revUpdated = _updateRevenuesIfProtocolIsSetUp(pioneer);

        if (!revUpdated) pioneerMintedAt[pioneer][tokenId] = block.timestamp;

        _safeMint(pioneer, tokenId);

        emit OnRevShareNFTMinted(pioneer, tokenId);
    }

    /**
     * @notice Mint multiple tokens
     * @param pioneer The address to mint
     * @param tokensToMint Amount of NFTs
     * @dev Only callable by owner
     */
    function batchMint(
        address pioneer,
        uint256 tokensToMint
    ) external onlyOwner nonReentrant mintChecks(pioneer) {
        require(tokensToMint > 1, RevShareNFT__BatchMintMoreThanOne());

        uint256 firstNewTokenId = totalSupply;
        totalSupply += tokensToMint; // Update the total supply to the last token ID that will be minted
        uint256 lastNewTokenId = firstNewTokenId + tokensToMint - 1;

        // Update the revenues if the contract is set up to do so
        bool revUpdated = _updateRevenuesIfProtocolIsSetUp(pioneer);

        for (uint256 i = firstNewTokenId; i <= lastNewTokenId; ++i) {
            if (!revUpdated) pioneerMintedAt[pioneer][i] = block.timestamp;
            _safeMint(pioneer, i);
        }

        emit OnBatchRevShareNFTMinted(pioneer, firstNewTokenId, lastNewTokenId);
    }

    /**
     * @notice Transfer override function. transfers are only allowed if the RevShareModule is set up
     * @dev The revenues are updated for both the sender and the receiver
     */
    function transfer(address to, uint256 tokenId) external {
        require(
            _fetchRevShareModuleAddressIfIsSetUp() != address(0),
            RevShareNFT__RevShareModuleNotSetUp()
        );

        // Update the revenues if the contract is set up to do so
        _updateRevenuesIfProtocolIsSetUp(msg.sender);
        _updateRevenuesIfProtocolIsSetUp(to);

        _safeTransfer(msg.sender, to, tokenId, "");
    }

    /**
     * @notice Transfer from override function. Only active NFTs can be transferred
     * @dev The revenues are updated for both the sender and the receiver
     */
    function transferFrom(
        address from,
        address to,
        uint256 tokenId
    ) public override(ERC721Upgradeable) {
        // The transfers are disable if the RevShareModule is not set up
        require(
            _fetchRevShareModuleAddressIfIsSetUp() != address(0),
            RevShareNFT__RevShareModuleNotSetUp()
        );

        // Update the revenues if the contract is set up to do so
        _updateRevenuesIfProtocolIsSetUp(from);
        _updateRevenuesIfProtocolIsSetUp(to);

        super.transferFrom(from, to, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return
            bytes(baseURI).length > 0
                ? string.concat(baseURI, Strings.toString(tokenId), ".json")
                : "";
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _fetchRevShareModuleAddressIfIsSetUp()
        internal
        view
        returns (address revShareModule_)
    {
        // If the addressManager is not set, we return address(0)
        if (address(addressManager) != address(0)) {
            // We try to fetch the RevShareModule address from the AddressManager, if it fails it means
            // the revenue share module is not set up, so we return address(0)
            try addressManager.getProtocolAddressByName("REVENUE_SHARE_MODULE") {
                revShareModule_ = addressManager
                    .getProtocolAddressByName("REVENUE_SHARE_MODULE")
                    .addr;
            } catch {}
        }
    }

    function _updateRevenuesIfProtocolIsSetUp(
        address _pioneer
    ) internal returns (bool revUpdated_) {
        address revShareModule = _fetchRevShareModuleAddressIfIsSetUp();

        if (revShareModule != address(0)) {
            // If the RevShareModule is set up, we update the revenues for the given address
            IRevShareModule(revShareModule).updateRevenue(_pioneer);
            revUpdated_ = true;
        }
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
