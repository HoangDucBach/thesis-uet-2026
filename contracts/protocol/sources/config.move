module protocol::config;

use protocol::constants::bps;

// === Consts ===
const VERSION: u64 = 1;
const DEFAULT_PROTOCOL_FEE_RATE_BPS: u64 = 2000;

// === Errors ===
const EInvalidPackageVersion: u64 = 0001;

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
    package_version: u64,
}

fun init(ctx: &mut TxContext) {
    let global_config = GlobalConfig {
        id: object::new(ctx),
        fee_rate_bps: DEFAULT_PROTOCOL_FEE_RATE_BPS,
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
    assert!(config.package_version == VERSION, EInvalidPackageVersion);
}
