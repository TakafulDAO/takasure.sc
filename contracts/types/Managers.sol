// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

/*//////////////////////////////////////////////////////////////
                               ADDRESSES
//////////////////////////////////////////////////////////////*/

// Types of addresses in the protocol
enum ProtocolAddressType {
    Admin, // Admin EOAs or multisigs
    Benefit, // Special type of module that manages benefits (e.g., life, farewell)
    Module, // Modules that are part of the protocol
    Protocol, // Core protocol contracts
    External, // External contracts (e.g., USDC, Chainlink)
    Helper // Helper contracts (e.g., UniswapV3MathHelper)
}

// Struct to represent an address in the protocol
struct ProtocolAddress {
    bytes32 name; // Name of the address, e.g., "FEE_CLAIM_ADDRESS", "TAKASURE_RESERVE", "KYC_MODULE"
    address addr;
    ProtocolAddressType addressType;
}

/*//////////////////////////////////////////////////////////////
                                 ROLES
//////////////////////////////////////////////////////////////*/

// The ProposedRoleHolder struct is used to propose a new role holder, it contains
// the proposed holder address and the proposal time. The proposal time is used to
// ensure that the proposal is valid for a certain period of time.
struct ProposedRoleHolder {
    address proposedHolder;
    uint256 proposalTime;
}

