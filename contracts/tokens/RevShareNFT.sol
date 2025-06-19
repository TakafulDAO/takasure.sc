//SPDX-License-Identifier: GPL-3.0

/**
 * @title RevShareNFT
 * @author Maikel Ordaz
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IRevShareModule} from "contracts/interfaces/IRevShareModule.sol";

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {AddressAndStates} from "contracts/helpers/libraries/checks/AddressAndStates.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

pragma solidity 0.8.28;

contract RevShareNFT is Ownable2Step, ReentrancyGuardTransient, ERC721 {
    using SafeERC20 for IERC20;

    address private immutable operator;
    IRevShareModule private revShareModule;
    string public baseURI; // Base URI for the NFTs

    uint256 public totalSupply; // Total supply of NFTs minted

    // Tokens 9181 to 18_000 are reserved for pioneers
    uint256 public constant MAX_SUPPLY = 18_000;
    // Not minted, but we'll assume it is minted for the revenue calculation
    // Tokens 1 to 9180 are reserved for owner
    uint256 private constant OWNER_BALANCE = 9_180;

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
    error RevShareNFT__BatchMintMoreThanOne();

    constructor(address _operator) Ownable(msg.sender) ERC721("RevShareNFT", "RSNFT") {
        AddressAndStates._notZeroAddress(_operator);

        operator = _operator;
    }

    /*//////////////////////////////////////////////////////////////
                                SETTINGS
    //////////////////////////////////////////////////////////////*/

    function setRevShareModule(address _revShareModule) external onlyOwner {
        AddressAndStates._notZeroAddress(_revShareModule);

        address oldRevShareModule = address(revShareModule);
        revShareModule = IRevShareModule(_revShareModule);

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
     * @notice Mint single token to a user
     * @param nftOwner The address of the member to mint a single NFT. This is only used for SINGLE_MINT
     * @dev Only callable by someone with owner
     */
    function mint(address nftOwner) external onlyOwner {
        AddressAndStates._notZeroAddress(nftOwner);
        require(totalSupply < MAX_SUPPLY, RevShareNFT__MaxSupplyReached());

        uint256 tokenId = totalSupply;
        ++totalSupply;

        // Update the revenues if the contract is set up to do so
        if (address(revShareModule) != address(0)) {
            IRevShareModule(revShareModule).updateRevenue(nftOwner);
            IRevShareModule(revShareModule).updateRevenue(operator);
        }

        _safeMint(nftOwner, tokenId);

        emit OnRevShareNFTMinted(nftOwner, tokenId);
    }

    /**
     * @notice Mint multiple tokens to a coupon buyer
     * @param nftOwner The address of the coupon buyer to mint the NFTs
     * @param tokensToMint Amount of NFTs
     * @dev Only callable by owner
     */
    function batchMint(address nftOwner, uint256 tokensToMint) external nonReentrant onlyOwner {
        AddressAndStates._notZeroAddress(nftOwner);
        require(totalSupply < MAX_SUPPLY, RevShareNFT__MaxSupplyReached());
        require(tokensToMint > 1, RevShareNFT__BatchMintMoreThanOne());

        uint256 firstNewTokenId = totalSupply;
        totalSupply += tokensToMint;
        uint256 lastNewTokenId = firstNewTokenId + tokensToMint;

        // Update the revenues if the contract is set up to do so
        if (address(revShareModule) != address(0)) {
            IRevShareModule(revShareModule).updateRevenue(nftOwner);
            IRevShareModule(revShareModule).updateRevenue(operator);
        }

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
        if (address(revShareModule) != address(0)) {
            IRevShareModule(revShareModule).updateRevenue(msg.sender);
            IRevShareModule(revShareModule).updateRevenue(to);
        }

        _safeTransfer(msg.sender, to, tokenId, "");
    }

    /**
     * @notice Transfer from override function. Only active NFTs can be transferred
     * @dev The revenues are updated for both the sender and the receiver
     */
    function transferFrom(address from, address to, uint256 tokenId) public override(ERC721) {
        // Update the revenues if the contract is set up to do so
        if (address(revShareModule) != address(0)) {
            IRevShareModule(revShareModule).updateRevenue(from);
            IRevShareModule(revShareModule).updateRevenue(to);
        }

        super.transferFrom(from, to, tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                                GETTERS
    //////////////////////////////////////////////////////////////*/

    function balanceOf(address owner) public view override(ERC721) returns (uint256) {
        if (owner == operator) return OWNER_BALANCE;
        return super.balanceOf(owner);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (tokenId >= OWNER_BALANCE) {
            _requireOwned(tokenId);
        }

        return
            bytes(baseURI).length > 0
                ? string.concat(baseURI, Strings.toString(tokenId), ".json")
                : "";
    }
}
