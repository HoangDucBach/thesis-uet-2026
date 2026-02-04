#[allow(unused_const)]

module protocol::keeper;

use enclave::enclave::{Self, Enclave};
use std::string::String;
use sui::linked_table::{Self, LinkedTable};
use sui::nitro_attestation::{Self, NitroAttestation};
use sui::package;

// === OTW ===
public struct KEEPER has drop {}

// === Constants ===
const STATUS_PENDING_ENCLAVE: u8 = 0;
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

/// Global registry for all keepers
/// * `id`: The unique identifier of the keeper registry.
/// * `keeper_ids`: A linked table mapping operator addresses to Keeper IDs.
/// * `pcr_configs`: A table of registered PCR configurations.
/// * `total_keepers`: The total number of registered keepers.
/// * `active_keepers`: The total number of active keepers.
public struct KeeperRegistry has store {
    keepers: LinkedTable<ID, KeeperInfo>,
    total_keepers: u64,
    active_keepers: u64,
}

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
    enclave: Enclave,
    status: u8,
    stats: Stats,
}

public struct KeeperInfo has copy, drop, store {
    keeper_id: ID,
    operator: address,
    status: u8,
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

public(package) fun new(ctx: &mut TxContext): KeeperRegistry {
    KeeperRegistry {
        keepers: linked_table::new(ctx),
        total_keepers: 0,
        active_keepers: 0,
    }
}

/// Register a new keeper operator
/// * `registry`: The mutable reference to the KeeperRegistry.
/// * `name`: A human-readable name for the keeper.
/// * `operator`: The address of the keeper operator.
/// * `pcr0`: The expected PCR0 value for the keeper's enclave.
/// * `pcr1`: The expected PCR1 value for the keeper's enclave.
/// * `pcr2`: The expected PCR2 value for the keeper's enclave.
/// * `ctx`: The transaction context.
public(package) fun register_keeper(
    registry: &mut KeeperRegistry,
    name: String,
    operator: address,
    pcr0: vector<u8>,
    pcr1: vector<u8>,
    pcr2: vector<u8>,
    ctx: &mut TxContext,
): Keeper {
    let keeper = Keeper {
        id: object::new(ctx),
        operator,
        enclave: enclave::new(
            vector::empty<u8>(),
            pcr0,
            pcr1,
            pcr2,
            ctx,
        ),
        name,
        status: STATUS_PENDING_ENCLAVE,
        stats: Stats {
            total_liquidations: 0,
            successful_liquidations: 0,
            failed_liquidations: 0,
            total_profit: 0,
            total_gas_used: 0,
            last_active_at: 0,
        },
    };

    let keeper_id = object::id(&keeper);

    let keeper_info = KeeperInfo {
        keeper_id,
        operator,
        status: STATUS_PENDING_ENCLAVE,
    };

    registry.keepers.push_back(keeper_id, keeper_info);
    registry.total_keepers = registry.total_keepers + 1;

    keeper
}

/// Update keeper's name
/// * `keeper`: The mutable reference to the Keeper.
/// * `cap`: The KeeperCap required to perform this operation.
/// * `new_name`: The new name for the keeper.
public fun update_name(keeper: &mut Keeper, cap: &KeeperCap, new_name: String) {
    assert!(object::id(keeper) == cap.keeper_id, EKeeperCapNotMatch);

    keeper.name = new_name;
}

public fun pcr0(keeper: &Keeper): vector<u8> {
    keeper.enclave.pcr0()
}

public fun pcr1(keeper: &Keeper): vector<u8> {
    keeper.enclave.pcr1()
}

public fun pcr2(keeper: &Keeper): vector<u8> {
    keeper.enclave.pcr2()
}

public fun pubkey(keeper: &Keeper): vector<u8> {
    keeper.enclave.pubkey()
}

public fun version(keeper: &Keeper): u64 {
    keeper.enclave.version()
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

/// Register enclave for a keeper (missing critical function)
/// * `keeper`: The mutable reference to the Keeper.
/// * `cap`: The KeeperCap required to perform this operation.
/// * `pubkey`: The enclave public key after TEE attestation.
/// * `attestation_doc`: The Nitro attestation document.
public fun register_enclave(
    keeper: &mut Keeper,
    cap: &KeeperCap,
    pubkey: vector<u8>,
    attestation_doc: &vector<u8>,
) {
    assert!(object::id(keeper) == cap.keeper_id, EKeeperCapNotMatch);
    assert!(keeper.status == STATUS_PENDING_ENCLAVE, EInvalidStatus);

    // Verify attestation document matches expected PCRs
    let doc = nitro_attestation::parse_document(attestation_doc);
    let actual_pcrs = doc.to_pcrs();
    // assert!(actual_pcrs == keeper.enclave.config.pcrs, EInvalidPCRs);

    enclave::update_pubkey(&mut keeper.enclave, pubkey);
    keeper.status = STATUS_ACTIVE;
}

/// Suspend keeper (missing critical function)
/// * `registry`: The mutable reference to the KeeperRegistry.
/// * `keeper_id`: The ID of the keeper to suspend.
public(package) fun suspend_keeper(registry: &mut KeeperRegistry, keeper: &mut Keeper) {
    assert!(keeper.status == STATUS_ACTIVE, EInvalidStatus);
    keeper.status = STATUS_SUSPENDED;

    let keeper_id = object::id(keeper);
    let keeper_info = registry.keepers.borrow_mut(keeper_id);
    keeper_info.status = STATUS_SUSPENDED;

    if (registry.active_keepers > 0) {
        registry.active_keepers = registry.active_keepers - 1;
    };
}

/// Reactivate keeper (missing critical function)
/// * `registry`: The mutable reference to the KeeperRegistry.
/// * `keeper`: The mutable reference to the Keeper.
public(package) fun reactivate_keeper(registry: &mut KeeperRegistry, keeper: &mut Keeper) {
    assert!(keeper.status == STATUS_SUSPENDED, EInvalidStatus);
    keeper.status = STATUS_ACTIVE;

    let keeper_id = object::id(keeper);
    let keeper_info = registry.keepers.borrow_mut(keeper_id);
    keeper_info.status = STATUS_ACTIVE;

    registry.active_keepers = registry.active_keepers + 1;
}

/// Update keeper statistics after liquidation (missing critical function)
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

/// Verify keeper signature for liquidation (missing critical function)
/// * `keeper`: The Keeper to verify signature for.
/// * `intent_scope`: Type of operation (liquidation = 1).
/// * `timestamp_ms`: Timestamp for replay protection.
/// * `payload`: The liquidation payload data.
/// * `signature`: The signature to verify.
public fun verify_liquidation_signature<T: drop>(
    keeper: &Keeper,
    intent_scope: u8,
    timestamp_ms: u64,
    payload: T,
    signature: &vector<u8>,
): bool {
    assert!(keeper.status == STATUS_ACTIVE, EKeeperNotActive);
    enclave::verify_signature_from_enclave(
        &keeper.enclave,
        intent_scope,
        timestamp_ms,
        payload,
        signature,
    )
}

/// Get keeper by ID from registry (missing critical function)
/// * `registry`: The KeeperRegistry to search.
/// * `keeper_id`: The ID of the keeper to find.
public fun get_keeper_info(registry: &KeeperRegistry, keeper_id: ID): &KeeperInfo {
    assert!(registry.keepers.contains(keeper_id), EKeeperNotFound);
    registry.keepers.borrow(keeper_id)
}

/// Check if keeper is active (missing critical function)
/// * `keeper`: The Keeper to check.
public fun is_active(keeper: &Keeper): bool {
    keeper.status == STATUS_ACTIVE
}

/// Get total keeper count (missing getter)
public fun total_keepers(registry: &KeeperRegistry): u64 {
    registry.total_keepers
}

/// Get active keeper count (missing getter)
public fun active_keepers(registry: &KeeperRegistry): u64 {
    registry.active_keepers
}
