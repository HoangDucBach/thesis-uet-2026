#[allow(unused_const)]

module protocol::keeper;

use enclave::enclave::{Self, Enclave, EnclaveCap, EnclaveConfig};
use std::string::String;
use sui::nitro_attestation::NitroAttestationDocument;
use sui::package;

// === OTW ===
public struct KEEPER has drop {}

// === Witness for Enclave Cap ===
public struct KeeperWitness has drop {}

// === Constants ===
const STATUS_PENDING: u8 = 0;
const STATUS_ACTIVE: u8 = 1;
const STATUS_SUSPENDED: u8 = 2;

// === Errors ===
const ENotWhitelisted: u64 = 3001;
const EAlreadyRegistered: u64 = 3002;
const EKeeperNotFound: u64 = 3003;
const EInvalidStatus: u64 = 3004;
const ENotKeeperOperator: u64 = 3005;
const EPCRNotRegistered: u64 = 3006;
const EEnclaveAlreadyRegistered: u64 = 3007;
const EInvalidSignature: u64 = 3008;
const EEnclaveExpired: u64 = 3009;
const EKeeperNotActive: u64 = 3010;
const EInvalidPCRLength: u64 = 3011;
const EKeeperCapNotMatch: u64 = 3012;

/// Keeper object representing a registered keeper operator
/// * `id`: The unique identifier of the keeper.
/// * `operator`: The address of the keeper operator.
/// * `name`: A human-readable name for the keeper.
/// * `pubkey`: The enclave public key (set after TEE registration).
/// * `pcr_hash`: The PCR hash that this keeper's enclave attested to.
/// * `status`: The current status of the keeper: pending_enclave | active | suspended.
/// * `registered_at`: When the keeper was registered.
/// * `enclave_expires_at`: When the enclave registration expires (0 if not registered).
/// * `stats`: Performance statistics for the keeper.
public struct Keeper has key, store {
    id: UID,
    operator: address,
    name: String,
    enclave_id: ID,
    status: u8,
    stats: Stats,
}

/// Keeper performance statistics
/// * `total_liquidations`: Total liquidations attempted
/// * `successful_liquidations`: Successful liquidations
/// * `failed_liquidations`: Failed liquidations
/// * `total_profit`: Total profit generated (in base units)
/// * `total_gas_used`: Total gas consumed
/// * `last_active_at`: Last active timestamp
public struct Stats has copy, drop, store {
    total_liquidations: u64,
    successful_liquidations: u64,
    failed_liquidations: u64,
    total_profit: u128,
    total_gas_used: u128,
    last_active_at: u64,
}

public struct KeeperCap has key {
    id: UID,
    keeper_id: ID,
}

// === Events ===

fun init(otw: KEEPER, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);
    let sender = ctx.sender();

    transfer::public_transfer(publisher, sender);
}

public(package) fun new(
    name: String,
    operator: address,
    enclave_id: ID,
    ctx: &mut TxContext,
): Keeper {
    Keeper {
        id: object::new(ctx),
        operator,
        enclave_id,
        name,
        status: STATUS_PENDING,
        stats: Stats {
            total_liquidations: 0,
            successful_liquidations: 0,
            failed_liquidations: 0,
            total_profit: 0,
            total_gas_used: 0,
            last_active_at: 0,
        },
    }
}

/// Utility function to create enclave config, enclave, and capability for keeper
/// * `name`: A human-readable name for the enclave configuration.
/// * `pcr0`: The expected PCR0 value for the enclave.
/// * `pcr1`: The expected PCR1 value for the enclave.
/// * `pcr2`: The expected PCR2 value for the enclave.
/// * `document`: The Nitro attestation document.
/// * `ctx`: Transaction context.
public fun create_enclave_with_config_and_cap(
    name: String,
    pcr0: vector<u8>,
    pcr1: vector<u8>,
    pcr2: vector<u8>,
    document: NitroAttestationDocument,
    ctx: &mut TxContext,
): (EnclaveConfig<KeeperWitness>, Enclave<KeeperWitness>, EnclaveCap<KeeperWitness>) {
    let enclave_cap = enclave::new_cap<KeeperWitness>(KeeperWitness {}, ctx);
    let enclave_config = enclave::create_enclave_config<KeeperWitness>(
        &enclave_cap,
        name,
        pcr0,
        pcr1,
        pcr2,
        ctx,
    );
    let enclave = enclave::new<KeeperWitness>(&enclave_config, document, ctx);

    (enclave_config, enclave, enclave_cap)
}

/// Suspend keeper
/// * `keeper`: The mutable reference to the Keeper.
public(package) fun suspend_keeper(keeper: &mut Keeper) {
    assert!(keeper.status == STATUS_ACTIVE, EInvalidStatus);
    keeper.status = STATUS_SUSPENDED;
}

/// Reactivate keeper
/// * `keeper`: The mutable reference to the Keeper.
public(package) fun reactivate_keeper(keeper: &mut Keeper) {
    assert!(keeper.status == STATUS_SUSPENDED, EInvalidStatus);
    keeper.status = STATUS_ACTIVE;
}

/// Update keeper statistics after liquidation
/// * `keeper`: The mutable reference to the Keeper.
/// * `cap`: The KeeperCap required to perform this operation.
/// * `success`: Whether the liquidation was successful.
/// * `profit`: The profit generated (0 if failed).
/// * `gas_used`: The gas consumed.
public fun update_stats(
    keeper: &mut Keeper,
    cap: &KeeperCap,
    success: bool,
    profit: u128,
    gas_used: u128,
    timestamp: u64,
) {
    assert!(object::id(keeper) == cap.keeper_id, EKeeperCapNotMatch);

    keeper.stats.total_liquidations = keeper.stats.total_liquidations + 1;
    if (success) {
        keeper.stats.successful_liquidations = keeper.stats.successful_liquidations + 1;
        keeper.stats.total_profit = keeper.stats.total_profit + profit;
    } else {
        keeper.stats.failed_liquidations = keeper.stats.failed_liquidations + 1;
    };
    keeper.stats.total_gas_used = keeper.stats.total_gas_used + gas_used;
    keeper.stats.last_active_at = timestamp;
}

/// Update keeper's name
/// * `keeper`: The mutable reference to the Keeper.
/// * `cap`: The KeeperCap required to perform this operation.
/// * `new_name`: The new name for the keeper.
public fun update_name(keeper: &mut Keeper, cap: &KeeperCap, new_name: String) {
    assert!(object::id(keeper) == cap.keeper_id, EKeeperCapNotMatch);

    keeper.name = new_name;
}

// === Getters ===

public fun enclave_id(keeper: &Keeper): ID {
    keeper.enclave_id
}

public fun status(keeper: &Keeper): u8 {
    keeper.status
}

public fun operator(keeper: &Keeper): address {
    keeper.operator
}

public fun name(keeper: &Keeper): String {
    keeper.name
}

/// Check if keeper is active
/// * `keeper`: The Keeper to check.
public fun is_active(keeper: &Keeper): bool {
    keeper.status == STATUS_ACTIVE
}
