#[allow(unused_const)]
module protocol::acl;

use std::option::is_some;
use sui::linked_table::{Self, LinkedTable};

// === Errors ===
const ERoleNumberTooLarge: u64 = 4001;
const ERoleNumberNotFound: u64 = 4002;
const ERoleNotFound: u64 = 4003;
const EMemberNotFound: u64 = 4004;

/// (ACL) Access Control List struct that manages permissions for addresses.
/// * `permissions`: A linked table mapping addresses to their permission levels.
public struct ACL has store {
    permissions: LinkedTable<address, u128>,
}

/// Member struct representing an address and its associated permissions.
/// * `addr`: The address of the member.
/// * `permission`: The permission level of the member.
public struct Member has copy, drop, store {
    addr: address,
    permission: u128,
}

/// Create a new ACL instance
/// * `ctx` - Transaction context used to create the LinkedTable
/// Returns an empty ACL with no members or permissions
public fun new(ctx: &mut TxContext): ACL {
    ACL { permissions: linked_table::new(ctx) }
}

/// Check if a member has a role in the ACL
/// * `acl` - The ACL instance to check
/// * `member` - The address of the member to check
/// * `role` - The role to check for
/// Returns true if the member has the role, false otherwise
public fun has_role(acl: &ACL, member: address, role: u8): bool {
    assert!(role < 128, ERoleNumberTooLarge);
    linked_table::contains(&acl.permissions, member) && *linked_table::borrow(
            &acl.permissions,
            member
        ) & (1 << role) > 0
}

/// Set roles for a member in the ACL
/// * `acl` - The ACL instance to update
/// * `member` - The address of the member to set roles for
/// * `permissions` - Permissions for the member, represented as a `u128` with each bit representing the presence of (or lack of) each role
public fun set_roles(acl: &mut ACL, member: address, permissions: u128) {
    if (linked_table::contains(&acl.permissions, member)) {
        *linked_table::borrow_mut(&mut acl.permissions, member) = permissions
    } else {
        linked_table::push_back(&mut acl.permissions, member, permissions);
    }
}

/// Add a role for a member in the ACL
/// * `acl` - The ACL instance to update
/// * `member` - The address of the member to add the role to
/// * `role` - The role to add
public fun add_role(acl: &mut ACL, member: address, role: u8) {
    assert!(role < 128, ERoleNumberTooLarge);
    if (linked_table::contains(&acl.permissions, member)) {
        let perms = linked_table::borrow_mut(&mut acl.permissions, member);
        *perms = *perms | (1 << role);
    } else {
        linked_table::push_back(&mut acl.permissions, member, 1 << role);
    }
}

/// Remove all roles of member
/// * `acl` - The ACL instance to update
/// * `member` - The address of the member to remove
public fun remove_member(acl: &mut ACL, member: address) {
    if (linked_table::contains(&acl.permissions, member)) {
        let _ = linked_table::remove(&mut acl.permissions, member);
    } else {
        abort EMemberNotFound
    }
}

/// Revoke a role for a member in the ACL
/// * `acl` - The ACL instance to update
/// * `member` - The address of the member to remove the role from
/// * `role` - The role to remove
public fun remove_role(acl: &mut ACL, member: address, role: u8) {
    assert!(role < 128, ERoleNumberTooLarge);
    if (has_role(acl, member, role)) {
        let perms = linked_table::borrow_mut(&mut acl.permissions, member);
        *perms = *perms ^ (1 << role);
    } else {
        abort ERoleNotFound
    }
}

/// Get all members
/// * `acl` - The ACL instance to get members from
/// Returns a vector of all members in the ACL
public fun get_members(acl: &ACL): vector<Member> {
    let mut members = vector::empty<Member>();
    let mut next_member_address = acl.permissions.front();
    while (is_some(next_member_address)) {
        let address = *option::borrow(next_member_address);
        members.push_back(Member {
            addr: address,
            permission: *acl.permissions.borrow(address),
        });
        next_member_address = acl.permissions.next(address);
    };
    members
}

/// Get the permission of member by address
/// * `acl` - The ACL instance to get permission from
/// * `address` - The address of the member to get permission for
/// Returns the permission of the member
public fun get_permission(acl: &ACL, address: address): u128 {
    if (!linked_table::contains(&acl.permissions, address)) {
        0
    } else {
        *linked_table::borrow(&acl.permissions, address)
    }
}
