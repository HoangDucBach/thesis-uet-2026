module protocol::sponsor_pool;

use protocol::config;
use protocol::constants::{acc_precision, bps};
use protocol::position::{Self, PositionManager, Position};
use std::bool;
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

public struct AdminCap has key, store {
    id: UID,
}

public struct SponsorCapability has key {
    id: UID,
}

/// The SponsorPool struct represents a sponsor pool in the protocol.
/// * `id`: The unique identifier of the sponsor pool.
/// * `balance`: The balance of SUI tokens in the sponsor pool.
/// * `reward_balance`: The balance of reward tokens in the sponsor pool.
/// * `acc_reward_per_share`: The accumulated reward per share in the sponsor pool.
/// * `acc_gas_per_share`: The accumulated gas per share in the sponsor pool.
/// * `position_manager`: The PositionManager that manages the positions in the sponsor pool.
/// * `keeper_addr`: The address of the keeper for the sponsor pool.
/// * `index`: The index of the sponsor pool.
public struct SponsorPool<phantom RewardCoin> has key {
    id: UID,
    balance: Balance<SUI>,
    reward_balance: Balance<RewardCoin>,
    total_shares: u128,
    acc_reward_per_share: u128,
    acc_gas_per_share: u128,
    position_manager: PositionManager,
    keeper_addr: address,
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

public(package) fun new<RewardCoin>(
    keeper_addr: address,
    url: String,
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
        keeper_addr,
        index,
        url,
    };
    pool
}

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
        sui::transfer::public_transfer(reward_coin, tx_context::sender(ctx));
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

public fun update_pool_accs<RewardCoin>(
    pool: &mut SponsorPool<RewardCoin>,
    additional_reward: u128,
    additional_gas: u128,
) {
    update_pool_accs_internal(pool, additional_reward, additional_gas);
}
