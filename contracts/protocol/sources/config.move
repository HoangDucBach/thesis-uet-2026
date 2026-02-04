#[allow(unused_const)]
module protocol::config;

use protocol::acl::{Self, ACL};
use protocol::constants::bps;
use sui::dynamic_field;

// === Consts ===
const VERSION: u64 = 1;
const DEFAULT_PROTOCOL_FEE_RATE_BPS: u64 = 2000;
const EMERGENCY_PAUSE_VERSION: u64 = 9223372036854775808; // u64::MAX / 2
const EMERGENCY_PAUSE_BEFORE_VERSION: vector<u8> = b"emergency_pause_before";

// === Roles ===
const ROLE_ADMIN: u8 = 0; // Full access
const ROLE_POSITION_MANAGER: u8 = 1; // Manage positions
const ROLE_GUARDIAN: u8 = 2; // Emergency pause
const ROLE_FEE_MANAGER: u8 = 3; // Update fee configs

// === INTENT SCOPE
const INTENT_LIQUIDATION: u8 = 0;
const INTENT_UPDATE_CONFIG: u8 = 1;
const INTENT_HAVEREST_REWARDS: u8 = 2;

// === Errors ===
const EInvalidPackageVersion: u64 = 0001;
const ENoRoleAdminPermission: u64 = 0002;
const ENoRoleOperatorPermission: u64 = 0003;
const ENoRoleKeeperPermission: u64 = 0004;
const ENoRoleGuardianPermission: u64 = 0005;
const ENoRoleFeeManagerPermission: u64 = 0006;
const EProtocolAlreadyEmergencyPause: u64 = 0007;
const EProtocolNotEmergencyPause: u64 = 0008;

public struct AdminCap has key, store {
    id: UID,
}

/// The GlobalConfig struct represents the global configuration of the protocol.
/// * `id`: The unique identifier of the global configuration.
/// * `fee_rate_bps`: The protocol fee rate in basis points.
/// * `package_version`: The version of the protocol package.
public struct GlobalConfig has key, store {
    id: UID,
    fee_rate_bps: u64,
    acl: ACL,
    package_version: u64,
}

fun init(ctx: &mut TxContext) {
    let global_config = GlobalConfig {
        id: object::new(ctx),
        fee_rate_bps: DEFAULT_PROTOCOL_FEE_RATE_BPS,
        acl: acl::new(ctx),
        package_version: VERSION,
    };

    let admin_cap = AdminCap { id: object::new(ctx) };

    transfer::public_transfer(admin_cap, tx_context::sender(ctx));
    transfer::share_object(global_config);
}

/// Updates the protocol fee rate.
/// * `config`: The mutable reference to the GlobalConfig.
/// * `new_fee_rate_bps`: The new fee rate in basis points.
/// * `_admin`: The AdminCap required to perform this operation.
public fun update_fee_rate(config: &mut GlobalConfig, new_fee_rate_bps: u64, _admin: &AdminCap) {
    assert!(new_fee_rate_bps as u128 <= bps(), 1001);
    config.fee_rate_bps = new_fee_rate_bps;
}

public fun checked_package_version(config: &GlobalConfig) {
    assert!(config.package_version >= VERSION, EInvalidPackageVersion);
}

/// Set role for member.
/// * `admin_cap` - The admin cap
/// * `config` - The global config
/// * `member` - The member address
/// * `roles` - The roles
public fun set_roles(_: &AdminCap, config: &mut GlobalConfig, member: address, roles: u128) {
    checked_package_version(config);
    acl::set_roles(&mut config.acl, member, roles);
}

/// Add a role for member.
/// * `admin_cap` - The admin cap
/// * `config` - The global config
/// * `member` - The member address
/// * `role` - The role
public fun add_role(_: &AdminCap, config: &mut GlobalConfig, member: address, role: u8) {
    checked_package_version(config);
    acl::add_role(&mut config.acl, member, role);
}

public fun check_role_admin(config: &GlobalConfig, member: address) {
    assert!(acl::has_role(&config.acl, member, ROLE_ADMIN), ENoRoleAdminPermission);
}

public fun check_role_operator(config: &GlobalConfig, member: address) {
    assert!(acl::has_role(&config.acl, member, ROLE_POSITION_MANAGER), ENoRoleOperatorPermission);
}

public fun check_role_guardian(config: &GlobalConfig, member: address) {
    assert!(acl::has_role(&config.acl, member, ROLE_GUARDIAN), ENoRoleGuardianPermission);
}

public fun emergency_pause(config: &mut GlobalConfig, ctx: &mut TxContext) {
    check_role_guardian(config, tx_context::sender(ctx));

    let old_version = config.package_version;
    config.package_version = EMERGENCY_PAUSE_VERSION;
    assert!(
        !dynamic_field::exists_with_type<vector<u8>, u64>(
            &config.id,
            EMERGENCY_PAUSE_BEFORE_VERSION,
        ),
        EProtocolAlreadyEmergencyPause,
    );
    dynamic_field::add(&mut config.id, EMERGENCY_PAUSE_BEFORE_VERSION, old_version);
}

public fun emergency_unpause(config: &mut GlobalConfig, new_version: u64, ctx: &mut TxContext) {
    check_role_guardian(config, tx_context::sender(ctx));
    assert!(
        dynamic_field::exists_with_type<vector<u8>, u64>(
            &config.id,
            EMERGENCY_PAUSE_BEFORE_VERSION,
        ),
        EProtocolNotEmergencyPause,
    );
    let before_version = dynamic_field::remove<vector<u8>, u64>(
        &mut config.id,
        EMERGENCY_PAUSE_BEFORE_VERSION,
    );
    assert!(new_version >= before_version, EInvalidPackageVersion);
    config.package_version = new_version;
}

/// Get current protocol fee rate
public fun fee_rate_bps(config: &GlobalConfig): u64 {
    config.fee_rate_bps
}

/// Get current package version
public fun package_version(config: &GlobalConfig): u64 {
    config.package_version
}

/// Check if protocol is emergency paused
public fun is_emergency_paused(config: &GlobalConfig): bool {
    config.package_version == EMERGENCY_PAUSE_VERSION
}

/// Get ACL reference
public fun acl(config: &GlobalConfig): &acl::ACL {
    &config.acl
}
