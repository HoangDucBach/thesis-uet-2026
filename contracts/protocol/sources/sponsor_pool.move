#[allow(unused_const)]
module protocol::sponsor_pool;

use protocol::constants::bps;
use protocol::position::{Self, PositionManager, Position, PositionInfo};
use std::string::String;
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::package;
use sui::sui::SUI;

public struct SPONSOR_POOL has drop {}

// === Consts ===

// === Errors ===
const EZeroStake: u64 = 2401;
const EInsufficientStake: u64 = 2402;
const EPoolPositionMismatch: u64 = 2403;
const EInsufficientGasBalance: u64 = 2404;

public struct AdminCap has key, store {
    id: UID,
}

public struct SponsorCap has key {
    id: UID,
}

/// Capability to collect protocol fees
public struct ProtocolFeeCollectCap has key, store {
    id: UID,
}

/// The SponsorPool struct represents a sponsor pool in the protocol.
/// * `id`: The unique identifier of the sponsor pool.
/// * `balance`: The balance of SUI tokens in the sponsor pool.
/// * `reward_balance`: The balance of reward tokens in the sponsor pool (includes unclaimed protocol fees).
/// * `acc_reward_per_share`: The accumulated reward per share in the sponsor pool.
/// * `acc_gas_per_share`: The accumulated gas per share in the sponsor pool.
/// * `position_manager`: The PositionManager that manages the positions in the sponsor pool.
/// * `protocol_fee_rate_bps`: Protocol fee rate in basis points
/// * `keeper_fee_rate_bps`: Keeper fee rate in basis points
/// * `unclaimed_protocol_fee`: Accounting variable - tracks protocol fees collected but not yet claimed
/// * `keeper_id`: The ID of the keeper for the sponsor pool.
/// * `index`: The index of the sponsor pool.
public struct SponsorPool<phantom RewardCoin> has key, store {
    id: UID,
    balance: Balance<SUI>,
    reward_balance: Balance<RewardCoin>,
    total_shares: u128,
    acc_reward_per_share: u128,
    acc_gas_per_share: u128,
    position_manager: PositionManager,
    keeper_id: ID,
    protocol_fee_rate_bps: u64,
    keeper_fee_rate_bps: u64,
    unclaimed_protocol_fee: u64,
    index: u64,
    url: String,
}

fun init(otw: SPONSOR_POOL, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);
    let admin_cap = AdminCap { id: object::new(ctx) };
    let sender = tx_context::sender(ctx);

    transfer::public_transfer(publisher, sender);
    transfer::public_transfer(admin_cap, sender);
}

/// Create a new SponsorPool instance
/// * `keeper_id`: The ID of the keeper for the sponsor pool.
/// * `url`: The URL associated with the sponsor pool.
/// * `protocol_fee_rate_bps`: Protocol fee rate in basis points
/// * `keeper_fee_rate_bps`: Keeper fee rate in basis points
/// * `index`: The index of the sponsor pool.
/// * `ctx`: The transaction context used to create the SponsorPool.
public(package) fun new<RewardCoin>(
    keeper_id: ID,
    url: String,
    protocol_fee_rate_bps: u64,
    keeper_fee_rate_bps: u64,
    index: u64,
    ctx: &mut TxContext,
): SponsorPool<RewardCoin> {
    let pool = SponsorPool<RewardCoin> {
        id: object::new(ctx),
        balance: balance::zero<SUI>(),
        reward_balance: balance::zero<RewardCoin>(),
        total_shares: 0,
        acc_reward_per_share: 0,
        acc_gas_per_share: 0,
        position_manager: position::new(ctx),
        protocol_fee_rate_bps,
        keeper_fee_rate_bps,
        unclaimed_protocol_fee: 0,
        keeper_id,
        index,
        url,
    };
    pool
}

/// Open a new position in the sponsor pool
/// * `pool`: The mutable reference to the SponsorPool.
/// * `ctx`: The transaction context used to create the position.
public fun open_position<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    ctx: &mut TxContext,
): Position {
    let pool_id = object::id(pool);

    let position = position::open_position(
        &mut pool.position_manager,
        pool_id,
        pool.index,
        pool.url,
        ctx,
    );
    position
}

/// Close a position in the sponsor pool
/// * `pool`: The mutable reference to the SponsorPool.
/// * `position`: The Position to be closed.
public fun close_position<RewardCoin>(pool: &mut SponsorPool<RewardCoin>, position: Position) {
    position::close_position(&mut pool.position_manager, position);
}

public fun stake<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    position: &mut Position,
    balance: Balance<SUI>,
) {
    let amount = balance.value();

    assert!(amount > 0, EZeroStake);
    assert!(position.pool_id() == object::id(pool), EPoolPositionMismatch);

    stake_internal(pool, position, balance)
}

public fun withdraw_rewards<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    position: &mut Position,
): Balance<RewardCoin> {
    assert!(position::pool_id(position) == object::id(pool), EPoolPositionMismatch);

    let (pending_reward_scaled, _pending_gas_scaled) = position::harvest(
        position,
        &mut pool.position_manager,
        pool.acc_reward_per_share,
        pool.acc_gas_per_share,
    );

    let reward_amount = (pending_reward_scaled / protocol::constants::acc_precision()) as u64;

    if (reward_amount > 0) {
        balance::split(&mut pool.reward_balance, reward_amount)
    } else {
        balance::zero()
    }
}

public fun withdraw_gas<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    position: &mut Position,
): Balance<SUI> {
    assert!(position::pool_id(position) == object::id(pool), EPoolPositionMismatch);

    let (_pending_reward_scaled, pending_gas_scaled) = position::harvest(
        position,
        &mut pool.position_manager,
        pool.acc_reward_per_share,
        pool.acc_gas_per_share,
    );

    let gas_amount = (pending_gas_scaled / protocol::constants::acc_precision()) as u64;

    if (gas_amount > 0) {
        balance::split(&mut pool.balance, gas_amount)
    } else {
        balance::zero()
    }
}

#[allow(lint(self_transfer))]
public fun unstake<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    position: &mut Position,
    amount: u64,
    ctx: &mut TxContext,
): Balance<SUI> {
    assert!(amount > 0, EZeroStake);
    assert!(position::pool_id(position) == object::id(pool), EPoolPositionMismatch);

    let shares_to_remove = amount as u128;

    let (pending_reward_scaled, pending_gas_scaled) = position::harvest(
        position,
        &mut pool.position_manager,
        pool.acc_reward_per_share,
        pool.acc_gas_per_share,
    );

    let reward_amount = (pending_reward_scaled / protocol::constants::acc_precision()) as u64;
    if (reward_amount > 0) {
        let reward_coin = coin::take(&mut pool.reward_balance, reward_amount, ctx);
        transfer::public_transfer(reward_coin, tx_context::sender(ctx));
    };

    pool.total_shares = pool.total_shares - shares_to_remove;

    position::decrement_shares(
        position,
        &mut pool.position_manager,
        shares_to_remove,
        pool.acc_reward_per_share,
        pool.acc_gas_per_share,
    );

    let gas_cost = (pending_gas_scaled / protocol::constants::acc_precision()) as u64;

    let mut principal = balance::split(&mut pool.balance, amount);

    if (gas_cost > 0) {
        if (gas_cost >= amount) {
            balance::join(&mut pool.balance, principal);
            return balance::zero()
        } else {
            let gas_payment = balance::split(&mut principal, gas_cost);
            balance::join(&mut pool.balance, gas_payment);
        }
    };

    principal
}

/// Take gas from the sponsor pool for keeper
/// * `pool`: The mutable reference to the SponsorPool.
/// * `amount`: The amount of gas to take.
/// * `ctx`: The transaction context used to create the gas coin.
public(package) fun take_gas<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    amount: u64,
    ctx: &mut TxContext,
): Coin<SUI> {
    assert!(balance::value(&pool.balance) >= amount, EInsufficientGasBalance);
    coin::take(&mut pool.balance, amount, ctx)
}

fun stake_internal<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    position: &mut Position,
    balance: Balance<SUI>,
) {
    let amount = balance.value();
    pool.balance.join(balance);

    let current_acc_reward_per_share = pool.acc_reward_per_share;
    let current_acc_gas_per_share = pool.acc_gas_per_share;
    let shares = amount as u128;

    pool.total_shares = pool.total_shares + shares;

    position::increment_shares(
        position,
        &mut pool.position_manager,
        shares,
        current_acc_reward_per_share,
        current_acc_gas_per_share,
    )
}

fun update_pool_accs_internal<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    additional_reward: u128,
    additional_gas: u128,
) {
    let total_shares = pool.total_shares;

    if (total_shares > 0) {
        let reward_increment =
            (additional_reward * protocol::constants::acc_precision()) / total_shares;
        pool.acc_reward_per_share = pool.acc_reward_per_share + reward_increment;

        let gas_increment = (additional_gas * protocol::constants::acc_precision()) / total_shares;
        pool.acc_gas_per_share = pool.acc_gas_per_share + gas_increment;
    }
}

public(package) fun update_pool_accs<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    additional_reward: u128,
    additional_gas: u128,
) {
    update_pool_accs_internal(pool, additional_reward, additional_gas);
}

/// Distribute rewards with automatic fee deduction
/// This ensures fees are properly accounted before stakers receive rewards
public(package) fun distribute_rewards<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    gross_reward_amount: u64,
    keeper_addr: address,
    ctx: &mut TxContext,
) {
    // Calculate fees
    let gross_value = gross_reward_amount as u128;
    let protocol_fee_amt = (gross_value * (pool.protocol_fee_rate_bps as u128)) / bps();
    let keeper_fee_amt = (gross_value * (pool.keeper_fee_rate_bps as u128)) / bps();

    // Pay keeper instantly (if fee > 0)
    if (keeper_fee_amt > 0) {
        let keeper_coin = coin::take(&mut pool.reward_balance, (keeper_fee_amt as u64), ctx);
        transfer::public_transfer(keeper_coin, keeper_addr);
    };

    // Record protocol fee for lazy collection (if fee > 0)
    if (protocol_fee_amt > 0) {
        pool.unclaimed_protocol_fee = pool.unclaimed_protocol_fee + (protocol_fee_amt as u64);
    };

    // Update accumulators with NET rewards (after deducting both fees)
    let net_reward_for_stakers = gross_value - keeper_fee_amt - protocol_fee_amt;
    update_pool_accs_internal(pool, net_reward_for_stakers, 0);
}

/// Collect accumulated protocol fees (Admin Action)
/// Only holders of ProtocolFeeCollectCap can call this (similar to Cetus pattern)
public fun collect_protocol_fee<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    _cap: &ProtocolFeeCollectCap,
    ctx: &mut TxContext,
): Coin<RewardCoin> {
    let amount = pool.unclaimed_protocol_fee;
    assert!(amount > 0, 0); // ENoProtocolFee

    // Safety check: ensure pool has enough balance
    assert!(balance::value(&pool.reward_balance) >= amount, 1); // EInsufficientBalance

    // Reset accounting
    pool.unclaimed_protocol_fee = 0;

    // Take the fee from reward balance
    coin::take(&mut pool.reward_balance, amount, ctx)
}

/// Add SUI balance to pool
public(package) fun add_sui_balance<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    balance: Balance<SUI>,
) {
    pool.balance.join(balance);
}

/// Get position manager reference
public fun position_manager<RewardCoin>(pool: &SponsorPool<RewardCoin>): &PositionManager {
    &pool.position_manager
}

/// Get mutable position manager reference (needed for liquidation)
public(package) fun position_manager_mut<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
): &mut PositionManager {
    &mut pool.position_manager
}

public fun acc_reward_per_share<RewardCoin>(pool: &SponsorPool<RewardCoin>): u128 {
    pool.acc_reward_per_share
}

public fun acc_gas_per_share<RewardCoin>(pool: &SponsorPool<RewardCoin>): u128 {
    pool.acc_gas_per_share
}

public fun get_position_info<RewardCoin>(
    pool: &SponsorPool<RewardCoin>,
    position_id: ID,
): &PositionInfo {
    position::get_position_info(&pool.position_manager, position_id)
}

public fun total_shares<RewardCoin>(pool: &SponsorPool<RewardCoin>): u128 {
    pool.total_shares
}

public fun keeper_id<RewardCoin>(pool: &SponsorPool<RewardCoin>): ID {
    pool.keeper_id
}

public fun index<RewardCoin>(pool: &SponsorPool<RewardCoin>): u64 {
    pool.index
}

public fun unclaimed_protocol_fee<RewardCoin>(pool: &SponsorPool<RewardCoin>): u64 {
    pool.unclaimed_protocol_fee
}

#[test_only]
public fun new_for_testing<RewardCoin>(
    keeper_id: ID,
    protocol_fee_rate_bps: u64,
    keeper_fee_rate_bps: u64,
    url: String,
    index: u64,
    ctx: &mut TxContext,
): SponsorPool<RewardCoin> {
    new<RewardCoin>(keeper_id, url, protocol_fee_rate_bps, keeper_fee_rate_bps, index, ctx)
}

#[test_only]
public fun new_sponsor_pool_custom_for_testing<RewardCoin>(
    keeper_id: ID,
    protocol_fee_rate_bps: u64,
    keeper_fee_rate_bps: u64,
    url: String,
    index: u64,
    initial_sui_balance: u64,
    initial_reward_balance: u64,
    total_shares: u128,
    acc_reward_per_share: u128,
    acc_gas_per_share: u128,
    ctx: &mut TxContext,
): SponsorPool<RewardCoin> {
    SponsorPool<RewardCoin> {
        id: object::new(ctx),
        balance: balance::create_for_testing<SUI>(initial_sui_balance),
        reward_balance: balance::create_for_testing<RewardCoin>(initial_reward_balance),
        total_shares,
        acc_reward_per_share,
        acc_gas_per_share,
        position_manager: position::new(ctx),
        protocol_fee_rate_bps,
        keeper_fee_rate_bps,
        unclaimed_protocol_fee: 0,
        keeper_id,
        index,
        url,
    }
}

#[test_only]
public fun balance_for_testing<RewardCoin>(pool: &SponsorPool<RewardCoin>): u64 {
    balance::value(&pool.balance)
}

#[test_only]
public fun reward_balance_for_testing<RewardCoin>(pool: &SponsorPool<RewardCoin>): u64 {
    balance::value(&pool.reward_balance)
}

/// Add reward balance to pool (for testing)
#[test_only]
public fun add_reward_balance<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    balance: Balance<RewardCoin>,
) {
    pool.reward_balance.join(balance);
}
