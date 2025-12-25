// SPDX-License-Identifier: GNU GPLv3

pragma solidity 0.8.28;

// Possible states a module can be in
enum ModuleState {
    Unset, // Default state
    Disabled, // It will disable selected functionalities
    Enabled, // Everything is enabled
    Paused, // All the functionalities are temporarily paused
    Deprecated // The module is deprecated, and no new interactions are allowed. This state cannot be changed
}

enum AssociationMemberState {
    Inactive, // Default state. The member has not been activated yet
    Active, // The member has paid the association membership and performed KYC
    PendingCancelation, // The member has requested to cancel the association membership
    Canceled // The member has canceled the association membership
}

enum BenefitMemberState {
    Inactive, // Default state. The member has not paid any benefit yet. From Inactive can only go to Active
    Active, // The member has paid the benefit contribution. From Active can change to: Defaulted, Canceled, Deceased
    PendingCancelation, // The member has requested to cancel their benefit membership. From PendingCancelation can change to: Active, Canceled
    Canceled, // The member has canceled their benefit membership. From Canceled can change to: Active
    Deceased // The member is deceased. This state is final and cannot be changed
}

