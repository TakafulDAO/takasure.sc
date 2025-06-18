//SPDX-License-Identifier: GPL-3.0

/**
 * @title RevShareNFT
 * @author Maikel Ordaz
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

pragma solidity 0.8.28;

contract RevShareNFT is Ownable2Step, ReentrancyGuardTransient, ERC721 {
    using SafeERC20 for IERC20;

    address private immutable takadaoOperator;
    address private revShareModule;
    string public baseURI; // Base URI for the NFTs

    uint256 public totalSupply; // Total supply of NFTs minted

    uint256 public constant NFT_PRICE = 250e6; // 250 USDC, this is the max contribution
    // Tokens 9181 to 18_000 are reserved for coupon buyers
    uint256 public constant MAX_SUPPLY = 18_000;
    // Not minted, but we'll assume it is minted for the revenue calculation
    // Tokens 1 to 9180 are reserved for Takadao
    uint256 private constant TAKADAO_BALANCE = 9_180;
    uint256 private constant DECIMAL_CORRECTION = 1e6;

    /*//////////////////////////////////////////////////////////////
                            EVENTS & ERRORS
    //////////////////////////////////////////////////////////////*/

    event OnRevShareModuleSet(address indexed oldRevShareModule, address indexed newRevShareModule);
    event OnBaseURISet(string indexed oldBaseUri, string indexed newBaseURI);
    event OnRevShareNFTMinted(address indexed owner, uint256 tokenId);
    event OnBatchRevShareNFTMinted(
        address indexed couponBuyer,
        uint256 initialTokenId,
        uint256 lastTokenId
    );

    error RevShareNFT__MaxSupplyReached();

    constructor(address _operator) Ownable(msg.sender) ERC721("RevShareNFT", "RSNFT") {
        AddressAndStates._notZeroAddress(_operator);

        takadaoOperator = _operator;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    function setRevShareModule(address _revShareModule) external onlyOwner {
        AddressAndStates._notZeroAddress(_revShareModule);

        address oldRevShareModule = revShareModule;
        revShareModule = _revShareModule;

        emit OnRevShareModuleSet(oldRevShareModule, _revShareModule);
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
     * @notice Mint single token to a user or activate an existing token from a coupon buyer
     * @param member The address of the member to mint a single NFT. This is only used for SINGLE_MINT
     * @dev Only callable by someone with owner
     */
    function mint(address member) external onlyOwner {
        AddressAndStates._notZeroAddress(member);
        require(totalSupply < MAX_SUPPLY, RevShareNFT__MaxSupplyReached());

        uint256 tokenId = totalSupply;
        ++totalSupply;

        // Update the revenues
        // _updateRevenue(member);
        // _updateRevenue(takadaoOperator);

        _safeMint(member, tokenId);

        emit OnRevShareNFTMinted(member, tokenId);
    }

    /**
     * @notice Mint multiple tokens to a coupon buyer
     * @param couponBuyer The address of the coupon buyer to mint the NFTs
     * @dev Only callable by owner
     */
    function batchMint(address couponBuyer, uint256 amountPaid) external nonReentrant onlyOwner {
        AddressAndStates._notZeroAddress(couponBuyer);
        require(totalSupply < MAX_SUPPLY, RevShareNFT__MaxSupplyReached());

        // Check how many NFTs the coupon buyer can mint
        uint256 maxNFTsAllowed = amountPaid / NFT_PRICE; // 550 / 250 = 2.2 => 2 NFTs

        uint256 firstNewTokenId = totalSupply;

        totalSupply += maxNFTsAllowed;

        if (maxNFTsAllowed == 1) {
            _safeMint(couponBuyer, firstNewTokenId);
            emit OnRevShareNFTMinted(couponBuyer, firstNewTokenId);
        } else {
            uint256 lastNewTokenId = firstNewTokenId + maxNFTsAllowed;

            for (uint256 i = firstNewTokenId; i < lastNewTokenId; ++i) {
                _safeMint(couponBuyer, i);
            }

            emit OnBatchRevShareNFTMinted(couponBuyer, firstNewTokenId, lastNewTokenId);
        }
    }

    /**
     * @notice Transfer override function. Only active NFTs can be transferred
     * @dev The revenues are updated for both the sender and the receiver
     */
    function transfer(address to, uint256 tokenId) external {
        // _updateRevenue(msg.sender);
        // _updateRevenue(to);

        _safeTransfer(msg.sender, to, tokenId, "");
    }

    /**
     * @notice Transfer from override function. Only active NFTs can be transferred
     * @dev The revenues are updated for both the sender and the receiver
     */
    function transferFrom(address from, address to, uint256 tokenId) public override(ERC721) {
        // _updateRevenue(from);
        // _updateRevenue(to);

        super.transferFrom(from, to, tokenId);
    }

    function balanceOf(address owner) public view override(ERC721) returns (uint256) {
        if (owner == takadaoOperator) return TAKADAO_BALANCE;
        return super.balanceOf(owner);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (tokenId >= TAKADAO_BALANCE) {
            _requireOwned(tokenId);
        }

        return
            bytes(baseURI).length > 0
                ? string.concat(baseURI, Strings.toString(tokenId), ".json")
                : "";
    }
}
