//SPDX-License-Identifier: GPL-3.0

/**
 * @title RevShareNFT
 * @author Maikel Ordaz
 */
import {IRevShareModule} from "contracts/interfaces/IRevShareModule.sol";
import {IAddressManager} from "contracts/interfaces/managers/IAddressManager.sol";

import {UUPSUpgradeable, Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";

import {ProtocolAddress} from "contracts/types/TakasureTypes.sol";
import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
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
    IAddressManager private addressManager;

    string public baseURI; // Base URI for the NFTs

    uint256 public totalSupply; // Total supply of NFTs minted

    mapping(address pioneer => mapping(uint256 tokenId => uint256 timestamp)) public pioneerMintedAt;

    uint256 public periodTransferLock; // Period after minting during which the NFT cannot be transferred

    uint256 public constant MAX_SUPPLY = 8_820;
    uint256 public constant OWNER_LOCK_KEY = type(uint256).max; // A key that will return the pioneer first minted at

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnAddressManagerSet(address indexed oldAddressManager, address indexed newAddressManager);
    event OnBaseURISet(string indexed oldBaseUri, string indexed newBaseURI);
    event OnPeriodTransferLockSet(uint256 indexed newPeriod);
    event OnRevShareNFTMinted(address indexed owner, uint256 tokenId);
    event OnBatchRevShareNFTMinted(address indexed newOwner, uint256 initialTokenId, uint256 lastTokenId);

    error RevShareNFT__NotAllowedAddress();
    error RevShareNFT__MaxSupplyReached();
    error RevShareNFT__BatchMintMoreThanOne();
    error RevShareNFT__TooEarlyToTransfer();
    error RevShareNFT__MintedAtNotSet();

    modifier mintChecks(address pioneer, uint256 toMint) {
        AddressAndStates._notZeroAddress(pioneer);
        require(pioneer != address(this), RevShareNFT__NotAllowedAddress());
        require(totalSupply + toMint <= MAX_SUPPLY, RevShareNFT__MaxSupplyReached());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(string memory _baseURI, address _owner) external initializer {
        __UUPSUpgradeable_init();
        __Ownable2Step_init();
        __Ownable_init(_owner);
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

    function setPeriodTransferLock(uint256 newPeriod) external onlyOwner {
        periodTransferLock = newPeriod;

        emit OnPeriodTransferLockSet(newPeriod);
    }

    /*//////////////////////////////////////////////////////////////
                                  MINT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Mint single token to a user
     * @param pioneer The address of the member to mint a single NFT. This is only used for SINGLE_MINT
     * @dev Only callable by someone with owner
     */
    function mint(address pioneer) external onlyOwner nonReentrant mintChecks(pioneer, 1) {
        // Update the revenues if the contract is set up to do so
        // Take current snapshot of totalSupply before it gets incremented
        _updateRevenuesIfProtocolIsSetUp(pioneer);

        uint256 tokenId = totalSupply;
        ++totalSupply;

        uint256 today = block.timestamp;
        pioneerMintedAt[pioneer][tokenId] = today;

        uint256 prev = pioneerMintedAt[pioneer][OWNER_LOCK_KEY];
        if (prev == 0 || today < prev) pioneerMintedAt[pioneer][OWNER_LOCK_KEY] = today; // Set the first minted at for the owner

        _safeMint(pioneer, tokenId);

        emit OnRevShareNFTMinted(pioneer, tokenId);
    }

    /**
     * @notice Mint multiple tokens
     * @param pioneer The address to mint
     * @param tokensToMint Amount of NFTs
     * @dev Only callable by owner
     */
    function batchMint(address pioneer, uint256 tokensToMint)
        external
        onlyOwner
        nonReentrant
        mintChecks(pioneer, tokensToMint)
    {
        require(tokensToMint > 1, RevShareNFT__BatchMintMoreThanOne());

        // Update the revenues if the contract is set up to do so
        // Take current snapshot of totalSupply before it gets incremented
        _updateRevenuesIfProtocolIsSetUp(pioneer);

        uint256 firstNewTokenId = totalSupply;
        totalSupply += tokensToMint; // Update the total supply to the last token ID that will be minted
        uint256 lastNewTokenId = firstNewTokenId + tokensToMint - 1;

        uint256 today = block.timestamp;
        for (uint256 i = firstNewTokenId; i <= lastNewTokenId; ++i) {
            pioneerMintedAt[pioneer][i] = today;
            _safeMint(pioneer, i);
        }

        uint256 prev = pioneerMintedAt[pioneer][OWNER_LOCK_KEY];
        if (prev == 0 || today < prev) pioneerMintedAt[pioneer][OWNER_LOCK_KEY] = today; // Set the first minted at for the owner

        emit OnBatchRevShareNFTMinted(pioneer, firstNewTokenId, lastNewTokenId);
    }

    /*//////////////////////////////////////////////////////////////
                               APPROVALS
    //////////////////////////////////////////////////////////////*/

    function approve(address to, uint256 tokenId) public override {
        address pioneer = _ownerOf(tokenId);

        // Only gate when granting approval, not when revoking
        if (to != address(0)) {
            require(
                block.timestamp >= pioneerMintedAt[pioneer][tokenId] + periodTransferLock,
                RevShareNFT__TooEarlyToTransfer()
            );
        }
        super.approve(to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) public override {
        // Only gate when granting approval, not when revoking
        if (approved) {
            require(
                block.timestamp >= pioneerMintedAt[msg.sender][OWNER_LOCK_KEY] + periodTransferLock,
                RevShareNFT__TooEarlyToTransfer()
            );
        }
        super.setApprovalForAll(operator, approved);
    }

    /*//////////////////////////////////////////////////////////////
                               TRANSFERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Transfers are only allowed if the lock period has passed
     * @dev The revenues are updated for both the sender and the receiver
     */
    function transfer(address to, uint256 tokenId) external nonReentrant {
        uint256 ts = pioneerMintedAt[msg.sender][tokenId]; // Minted at from current owner
        require(ts != 0, RevShareNFT__MintedAtNotSet()); // The token must be owned
        require(block.timestamp >= ts + periodTransferLock, RevShareNFT__TooEarlyToTransfer());

        // Update the revenues if the contract is set up to do so
        _updateRevenuesIfProtocolIsSetUp(msg.sender);
        _updateRevenuesIfProtocolIsSetUp(to);

        _safeTransfer(msg.sender, to, tokenId, "");

        // Get the minted at for the new owner
        uint256 prev = pioneerMintedAt[to][OWNER_LOCK_KEY];
        if (prev == 0 || ts < prev) pioneerMintedAt[to][OWNER_LOCK_KEY] = ts; // Set the first minted at for the new owner
        pioneerMintedAt[to][tokenId] = ts; // Set the minted at for the new owner

        delete pioneerMintedAt[msg.sender][tokenId]; // Delete the minted at for the previous owner
    }

    /**
     * @notice Transfer from override function. Only active NFTs can be transferred
     * @dev The revenues are updated for both the sender and the receiver
     */
    function transferFrom(address from, address to, uint256 tokenId) public override(ERC721Upgradeable) nonReentrant {
        uint256 ts = pioneerMintedAt[from][tokenId]; // Minted at from current owner
        require(ts != 0, RevShareNFT__MintedAtNotSet()); // The token must be owned
        require(block.timestamp >= ts + periodTransferLock, RevShareNFT__TooEarlyToTransfer());

        // Update the revenues if the contract is set up to do so
        _updateRevenuesIfProtocolIsSetUp(from);
        _updateRevenuesIfProtocolIsSetUp(to);

        super.transferFrom(from, to, tokenId);

        // Get the minted at for the new owner
        uint256 prev = pioneerMintedAt[to][OWNER_LOCK_KEY];
        if (prev == 0 || ts < prev) pioneerMintedAt[to][OWNER_LOCK_KEY] = ts; // Set the first minted at for the new owner
        pioneerMintedAt[to][tokenId] = ts; // Set the minted at for the new owner

        delete pioneerMintedAt[from][tokenId]; // Delete the minted at for the previous owner
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        // Token must be owned
        _requireOwned(tokenId);
        return bytes(baseURI).length > 0 ? string.concat(baseURI, Strings.toString(tokenId), ".json") : "";
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _fetchRevShareModuleAddressIfIsSetUp() internal view returns (address revShareModule_) {
        // If the addressManager is not set, we return address(0)
        if (address(addressManager) != address(0)) {
            // We try to fetch the RevShareModule address from the AddressManager, if it fails it means
            // the revenue share module is not set up, so we return address(0)
            try addressManager.getProtocolAddressByName("MODULE__REVSHARE") returns (
                ProtocolAddress memory protocolAddress
            ) {
                revShareModule_ = protocolAddress.addr;
            } catch {}
        }
    }

    function _updateRevenuesIfProtocolIsSetUp(address _pioneer) internal {
        address revShareModule = _fetchRevShareModuleAddressIfIsSetUp();

        // If the RevShareModule is set up, we update the revenues for the given address
        if (revShareModule != address(0)) IRevShareModule(revShareModule).updateRevenue(_pioneer);
    }

    ///@dev required by the OZ UUPS module
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Temporary function to migrate the pioneerMintedAt[owner][OWNER_LOCK_KEY] for existing owners
    function migrateOwnerFirstMintForRange(uint256 startId, uint256 endIdExclusive) external onlyOwner {
        require(endIdExclusive <= totalSupply, "range exceeds supply");
        for (uint256 id = startId; id < endIdExclusive; ++id) {
            address owner = _ownerOf(id);
            if (owner == address(0)) continue; // safety
            uint256 ts = pioneerMintedAt[owner][id];
            if (ts == 0) continue; // safety

            uint256 prev = pioneerMintedAt[owner][OWNER_LOCK_KEY];
            if (prev == 0 || ts < prev) {
                pioneerMintedAt[owner][OWNER_LOCK_KEY] = ts;
            }
        }
    }
}
