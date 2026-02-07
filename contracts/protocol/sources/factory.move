module protocol::factory;

use enclave::enclave::{Self, Enclave, EnclaveConfig, EnclaveCap};
use protocol::config::{Self, GlobalConfig, checked_package_version};
use protocol::keeper::{Self, Keeper, KeeperWitness};
use protocol::position::{Self, Position, PositionInfo};
use protocol::sponsor_pool::{Self, SponsorPool};
use std::string::String;
use sui::linked_table::{Self, LinkedTable};
use sui::nitro_attestation::NitroAttestationDocument;

// === Errors ===
const EInvalidFeeRateBps: u64 = 5001;
const EKeeperAlreadyHasSponsorPool: u64 = 5002;

public struct SimpleSponsorPool has copy, drop, store {
    sponsor_pool_id: ID,
    keeper_id: ID,
    fee_rate_bps: u64,
}

public struct SponsorPools has key, store {
    id: UID,
    list: LinkedTable<ID, SimpleSponsorPool>,
    index: u64,
}

fun init(ctx: &mut TxContext) {
    let sponsor_pools = SponsorPools {
        id: object::new(ctx),
        list: linked_table::new<ID, SimpleSponsorPool>(ctx),
        index: 0,
    };

    transfer::public_share_object(sponsor_pools);
}

#[allow(lint(self_transfer))]
public fun create_enclave_and_keeper(
    name: String,
    pcr0: vector<u8>,
    pcr1: vector<u8>,
    pcr2: vector<u8>,
    document: NitroAttestationDocument,
    ctx: &mut TxContext,
) {
    let (keeper, enclave_config, enclave, enclave_cap) = create_keeper_internal(
        name,
        pcr0,
        pcr1,
        pcr2,
        document,
        ctx,
    );

    transfer::public_share_object(keeper);
    transfer::public_share_object(enclave_config);
    transfer::public_share_object(enclave);
    transfer::public_transfer(enclave_cap, ctx.sender());
}

#[allow(lint(share_owned))]
entry fun create_sponsor_pool<RewardCoin>(
    sponsor_pools: &mut SponsorPools,
    config: &GlobalConfig,
    keeper_id: ID,
    url: String,
    fee_rate_bps: u64,
    index: u64,
    ctx: &mut TxContext,
) {
    checked_package_version(config);

    let sponsor_pool = create_sponsor_pool_internal<RewardCoin>(
        sponsor_pools,
        keeper_id,
        url,
        fee_rate_bps,
        index,
        ctx,
    );

    transfer::public_share_object(sponsor_pool);
}

fun create_sponsor_pool_internal<RewardCoin>(
    sponsor_pools: &mut SponsorPools,
    keeper_id: ID,
    url: String,
    fee_rate_bps: u64,
    index: u64,
    ctx: &mut TxContext,
): SponsorPool<RewardCoin> {
    assert!(fee_rate_bps <= config::max_keeper_fee_bps(), EInvalidFeeRateBps);

    let pool_key = new_sponsor_pool_key(keeper_id);

    assert!(!sponsor_pools.list.contains(pool_key), EKeeperAlreadyHasSponsorPool);

    // Create the sponsor pool
    let pool = sponsor_pool::new<RewardCoin>(keeper_id, url, fee_rate_bps, index, ctx);
    sponsor_pools.index = sponsor_pools.index + 1;
    let simple_pool = SimpleSponsorPool {
        sponsor_pool_id: object::id(&pool),
        keeper_id,
        fee_rate_bps,
    };
    sponsor_pools.list.push_back(pool_key, simple_pool);

    pool
}

fun create_keeper_internal(
    name: String,
    pcr0: vector<u8>,
    pcr1: vector<u8>,
    pcr2: vector<u8>,
    document: NitroAttestationDocument,
    ctx: &mut TxContext,
): (Keeper, EnclaveConfig<KeeperWitness>, Enclave<KeeperWitness>, EnclaveCap<KeeperWitness>) {
    let (enclave_config, enclave, enclave_cap) = keeper::create_enclave_with_config_and_cap(
        name,
        pcr0,
        pcr1,
        pcr2,
        document,
        ctx,
    );

    let enclave_config_id = object::id(&enclave_config);
    let enclave_id = object::id(&enclave);

    let keeper = keeper::new(
        name,
        ctx.sender(),
        enclave_id,
        ctx,
    );

    (keeper, enclave_config, enclave, enclave_cap)
}

public fun new_sponsor_pool_key(keeper_id: ID): ID {
    keeper_id
}

#[test_only]
public fun new_sponsor_pools_for_testing(ctx: &mut TxContext): SponsorPools {
    SponsorPools {
        id: object::new(ctx),
        list: linked_table::new<ID, SimpleSponsorPool>(ctx),
        index: 0,
    }
}
