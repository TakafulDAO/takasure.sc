//SPDX-License-Identifier: GPL-3.0

/**
 * @title RevShareNFT
 * @author Maikel Ordaz
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRevShareModule} from "contracts/interfaces/IRevShareModule.sol";
import {ITakasureReserve} from "contracts/interfaces/ITakasureReserve.sol";
import {IAddressManager} from "contracts/interfaces/IAddressManager.sol";

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

pragma solidity 0.8.28;

contract RevShareNFT is Ownable2Step, ReentrancyGuardTransient, ERC721 {
    using SafeERC20 for IERC20;

    ITakasureReserve private takasureReserve;

    address public immutable operator;
    string public baseURI; // Base URI for the NFTs

    uint256 public totalSupply; // Total supply of NFTs minted
    uint256 private mintedToOperator; // Updated on transfers from the operator
    uint256 private mintedToPioneers; // Updated on mints

    uint256 public constant MAX_SUPPLY = 18_000;
    uint256 private constant OPERATOR_RESERVED_TOKENS = 9_180; // 51% of the total supply reserved for operator
    uint256 private constant PIONEERS_RESERVED_TOKENS = 8_820; // 49% of the total supply reserved for pioneers

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnTakasureReserveSet(
        address indexed oldTakasureReserve,
        address indexed newTakasureReserve
    );
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

    constructor(
        address _operator,
        string memory _baseURI
    ) Ownable(msg.sender) ERC721("RevShareNFT", "RSNFT") {
        AddressAndStates._notZeroAddress(_operator);

        operator = _operator;
        baseURI = _baseURI;

        totalSupply = OPERATOR_RESERVED_TOKENS - 1; // We assume that the operator has 9180 tokens already minted and the tokenId starts at 0
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    function setTakasureReserve(address _takasureReserve) external onlyOwner {
        AddressAndStates._notZeroAddress(_takasureReserve);

        address oldTakasureReserve = address(takasureReserve);
        takasureReserve = ITakasureReserve(_takasureReserve);

        emit OnTakasureReserveSet(oldTakasureReserve, _takasureReserve);
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
     * @param nftOwner The address of the member to mint a single NFT. This is only used for SINGLE_MINT
     * @dev Only callable by someone with owner
     */
    function mint(address nftOwner) external onlyOwner {
        AddressAndStates._notZeroAddress(nftOwner);
        require(nftOwner != operator, RevShareNFT__NotAllowedAddress());
        require(
            totalSupply < MAX_SUPPLY && mintedToPioneers < PIONEERS_RESERVED_TOKENS,
            RevShareNFT__MaxSupplyReached()
        );

        uint256 tokenId = totalSupply;
        ++totalSupply;
        ++mintedToPioneers;

        // Update the revenues if the contract is set up to do so
        _updateRevenuesIfProtocolIsSetUp(nftOwner, operator);

        _safeMint(nftOwner, tokenId);

        emit OnRevShareNFTMinted(nftOwner, tokenId);
    }

    /**
     * @notice Mint multiple tokens
     * @param nftOwner The address to mint
     * @param tokensToMint Amount of NFTs
     * @dev Only callable by owner
     */
    function batchMint(address nftOwner, uint256 tokensToMint) external nonReentrant onlyOwner {
        AddressAndStates._notZeroAddress(nftOwner);
        require(nftOwner != operator, RevShareNFT__NotAllowedAddress());
        require(
            totalSupply < MAX_SUPPLY && mintedToPioneers < PIONEERS_RESERVED_TOKENS,
            RevShareNFT__MaxSupplyReached()
        );
        require(tokensToMint > 1, RevShareNFT__BatchMintMoreThanOne());

        uint256 firstNewTokenId = totalSupply;
        totalSupply += tokensToMint;
        mintedToPioneers += tokensToMint;
        uint256 lastNewTokenId = firstNewTokenId + tokensToMint;

        // Update the revenues if the contract is set up to do so
        _updateRevenuesIfProtocolIsSetUp(nftOwner, operator);

        for (uint256 i = firstNewTokenId; i < lastNewTokenId; ++i) {
            _safeMint(nftOwner, i);
        }

        emit OnBatchRevShareNFTMinted(nftOwner, firstNewTokenId, lastNewTokenId);
    }

    /**
     * @notice Transfer override function. Only active NFTs can be transferred
     * @dev The revenues are updated for both the sender and the receiver
     */
    function transfer(address to, uint256 tokenId) external {
        // Update the revenues if the contract is set up to do so
        _updateRevenuesIfProtocolIsSetUp(msg.sender, to);

        // If the caller is the operator, as all the balance is assumed but not minted,
        // then we mint the token to the recipient instead of transferring it
        if (msg.sender == operator) {
            require(mintedToOperator < OPERATOR_RESERVED_TOKENS, RevShareNFT__NotEnoughBalance());
            _safeMint(to, tokenId);
            ++mintedToOperator;
        } else {
            _safeTransfer(msg.sender, to, tokenId, "");
        }
    }

    /**
     * @notice Transfer from override function. Only active NFTs can be transferred
     * @dev The revenues are updated for both the sender and the receiver
     */
    function transferFrom(address from, address to, uint256 tokenId) public override(ERC721) {
        // Update the revenues if the contract is set up to do so
        _updateRevenuesIfProtocolIsSetUp(from, to);

        // If the caller is the operator, as all the balance is assumed but not minted,
        // then we mint the token to the recipient instead of transferring it
        if (from == operator) {
            require(mintedToOperator < OPERATOR_RESERVED_TOKENS, RevShareNFT__NotEnoughBalance());
            _safeMint(from, tokenId);
            ++mintedToOperator;
        }

        super.transferFrom(from, to, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function balanceOf(address owner) public view override(ERC721) returns (uint256) {
        if (owner == operator)
            return
                (OPERATOR_RESERVED_TOKENS - mintedToOperator) +
                (PIONEERS_RESERVED_TOKENS - mintedToPioneers);
        return super.balanceOf(owner);
    }

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
        if (address(takasureReserve) != address(0)) {
            try
                IAddressManager(takasureReserve.addressManager()).getProtocolAddressByName(
                    "REVENUE_SHARE_MODULE"
                )
            {
                revShareModule_ = IAddressManager(takasureReserve.addressManager())
                    .getProtocolAddressByName("REVENUE_SHARE_MODULE")
                    .addr;
            } catch {}
        }
    }

    function _updateRevenuesIfProtocolIsSetUp(address _a, address _b) internal {
        address revShareModule = _fetchRevShareModuleAddressIfIsSetUp();

        if (revShareModule != address(0)) {
            IRevShareModule(revShareModule).updateRevenue(_a);
            IRevShareModule(revShareModule).updateRevenue(_b);
        }
    }
}
