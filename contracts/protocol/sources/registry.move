#[allow(unused_const)]
module protocol::registry;

use protocol::config::{Self, GlobalConfig, AdminCap};
use protocol::keeper::{Self, KeeperRegistry};
use protocol::sponsor_pool::{Self, SponsorPool};
use std::string::String;
use sui::package;
use sui::table::{Self, Table};

// === OTW ===
public struct REGISTRY has drop {}

// === Constants ===
const DEFAULT_POOL_INDEX: u64 = 0;

// === Errors ===
const EInvalidPoolIndex: u64 = 5001;
const EPoolAlreadyExists: u64 = 5002;
const EUnauthorized: u64 = 5003;

// === Structs ===

/// Global protocol registry containing all pools and keepers
public struct ProtocolRegistry has key {
    id: UID,
    keeper_registry: KeeperRegistry,
    pool_count: u64,
    pools: Table<u64, ID>, // index -> pool_id mapping
    config_id: ID,
}

// === Functions ===

fun init(otw: REGISTRY, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);
    transfer::public_transfer(publisher, ctx.sender());
}

/// Initialize protocol registry (called by admin after deployment)
/// * `config`: Reference to global config for validation
/// * `admin_cap`: Admin capability proving authorization
/// * `ctx`: Transaction context
public fun initialize_registry(
    config: &GlobalConfig,
    admin_cap: &AdminCap,
    ctx: &mut TxContext,
): ProtocolRegistry {
    // Verify caller has admin permission
    config::check_role_admin(config, tx_context::sender(ctx));
    
    let registry = ProtocolRegistry {
        id: object::new(ctx),
        keeper_registry: keeper::new(ctx),
        pool_count: 0,
        pools: table::new(ctx),
        config_id: object::id(config),
    };
    
    registry
}

/// Create new sponsor pool
/// * `registry`: Mutable reference to protocol registry
/// * `config`: Reference to global config for ACL check
/// * `keeper_addr`: Address of keeper for this pool
/// * `url`: Pool metadata URL
/// * `ctx`: Transaction context
public fun create_pool<RewardCoin>(
    registry: &mut ProtocolRegistry,
    config: &GlobalConfig,
    keeper_addr: address,
    url: String,
    ctx: &mut TxContext,
): SponsorPool<RewardCoin> {
    // Verify caller has operator permission
    config::check_role_operator(config, tx_context::sender(ctx));
    
    let pool_index = registry.pool_count;
    
    let pool = sponsor_pool::new<RewardCoin>(
        keeper_addr,
        url,
        pool_index,
        ctx,
    );
    
    let pool_id = object::id(&pool);
    registry.pools.add(pool_index, pool_id);
    registry.pool_count = registry.pool_count + 1;
    
    pool
}

/// Register new keeper
/// * `registry`: Mutable reference to protocol registry
/// * `config`: Reference to global config for ACL check
/// * `name`: Human-readable keeper name
/// * `operator`: Keeper operator address
/// * `pcr0`, `pcr1`, `pcr2`: Expected PCR values
/// * `ctx`: Transaction context
public fun register_keeper(
    registry: &mut ProtocolRegistry,
    config: &GlobalConfig,
    name: String,
    operator: address,
    pcr0: vector<u8>,
    pcr1: vector<u8>,
    pcr2: vector<u8>,
    ctx: &mut TxContext,
) {
    // Verify caller has admin permission
    config::check_role_admin(config, tx_context::sender(ctx));
    
    let keeper = keeper::register_keeper(
        &mut registry.keeper_registry,
        name,
        operator,
        pcr0,
        pcr1,
        pcr2,
        ctx,
    );
    
    // Transfer keeper object to operator
    transfer::public_transfer(keeper, operator);
}

/// Get keeper registry reference
public fun keeper_registry(registry: &ProtocolRegistry): &KeeperRegistry {
    &registry.keeper_registry
}

/// Get pool count
public fun pool_count(registry: &ProtocolRegistry): u64 {
    registry.pool_count
}

/// Get pool ID by index
public fun get_pool_id(registry: &ProtocolRegistry, index: u64): ID {
    assert!(registry.pools.contains(index), EInvalidPoolIndex);
    *registry.pools.borrow(index)
}

/// Check if pool exists
public fun pool_exists(registry: &ProtocolRegistry, index: u64): bool {
    registry.pools.contains(index)
}

/// Get config ID
public fun config_id(registry: &ProtocolRegistry): ID {
    registry.config_id
}