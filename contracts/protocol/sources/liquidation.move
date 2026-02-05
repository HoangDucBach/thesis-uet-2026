#[allow(unused_const)]
module protocol::liquidation;

use protocol::config::{Self, GlobalConfig};
use protocol::keeper::{Self, Keeper, KeeperCap};
use protocol::position::{Self, PositionManager, Position};
use protocol::sponsor_pool::{Self, SponsorPool};
use std::string::String;
use sui::balance::{Self, Balance};
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::event;
use sui::sui::SUI;
use sui::tx_context::{Self, TxContext};

// === Constants ===
const INTENT_LIQUIDATION: u8 = 1;
const MIN_LIQUIDATION_AMOUNT: u64 = 100; // Minimum 0.1 SUI
const MAX_LIQUIDATION_RATIO: u128 = 8000; // 80% of position
const LIQUIDATION_PENALTY_BPS: u64 = 500; // 5% penalty to liquidated user
const LIQUIDATION_REWARD_BPS: u64 = 300; // 3% reward to keeper
const LIQUIDATION_PROTOCOL_BPS: u64 = 200; // 2% to protocol treasury

// === Errors ===
const EInvalidKeeperSignature: u64 = 4001;
const EPositionNotLiquidatable: u64 = 4002;
const EInsufficientGasDebt: u64 = 4003;
const ELiquidationAmountTooSmall: u64 = 4004;
const ELiquidationAmountTooLarge: u64 = 4005;
const EKeeperNotActive: u64 = 4006;
const EInvalidTimestamp: u64 = 4007;
const EPositionPoolMismatch: u64 = 4008;

// === Structs ===

/// Payload for liquidation signature verification
public struct LiquidationPayload has copy, drop {
    position_id: ID,
    liquidation_amount: u64,
    gas_debt: u128,
    nonce: u64,
}

// === Events ===

public struct LiquidationEvent has copy, drop {
    position_id: ID,
    liquidator: address,
    keeper_id: ID,
    liquidation_amount: u64,
    penalty_amount: u64,
    keeper_reward: u64,
    protocol_fee: u64,
    timestamp: u64,
}

// === Functions ===

/// Execute liquidation of an undercollateralized position
/// * `config`: Global configuration for ACL and fee settings
/// * `pool`: The sponsor pool containing the position
/// * `position`: The position to liquidate
/// * `keeper`: The keeper performing liquidation
/// * `keeper_cap`: Capability proving keeper ownership
/// * `liquidation_amount`: Amount to liquidate (in SUI base units)
/// * `signature`: Keeper's TEE signature proving liquidation validity
/// * `clock`: Clock for timestamp verification
/// * `ctx`: Transaction context
public fun execute_liquidation<RewardCoin>(
    config: &GlobalConfig,
    pool: &mut SponsorPool<RewardCoin>,
    position: &mut Position,
    keeper: &mut Keeper,
    keeper_cap: &KeeperCap,
    liquidation_amount: u64,
    gas_debt: u128,
    nonce: u64,
    signature: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<SUI> {
    // Verify global config is not paused
    config::checked_package_version(config);

    // Verify keeper is active and owns the capability
    assert!(keeper::is_active(keeper), EKeeperNotActive);

    // Verify position belongs to this pool
    assert!(position::pool_id(position) == object::id(pool), EPositionPoolMismatch);

    // Verify liquidation parameters
    assert!(liquidation_amount >= MIN_LIQUIDATION_AMOUNT, ELiquidationAmountTooSmall);
    assert!(
        liquidation_amount as u128 <= position::shares(position) * MAX_LIQUIDATION_RATIO / 10000,
        ELiquidationAmountTooLarge,
    );

    let timestamp_ms = clock::timestamp_ms(clock);
    let position_id = object::id(position);

    // Create payload for signature verification
    let payload = LiquidationPayload {
        position_id,
        liquidation_amount,
        gas_debt,
        nonce,
    };

    // Verify keeper's TEE signature
    let is_valid_signature = keeper::verify_liquidation_signature(
        keeper,
        INTENT_LIQUIDATION,
        timestamp_ms,
        payload,
        &signature,
    );
    assert!(is_valid_signature, EInvalidKeeperSignature);

    // Harvest position to update debt before liquidation
    sponsor_pool::update_pool_accs(pool, 0, gas_debt);
    let (_pending_reward, _pending_gas) = position::harvest(
        position,
        sponsor_pool::position_manager_mut(pool),
        sponsor_pool::acc_reward_per_share(pool),
        sponsor_pool::acc_gas_per_share(pool),
    );

    // Check if position is actually liquidatable (gas debt > threshold)
    assert!(_pending_gas >= gas_debt, EInsufficientGasDebt);

    // Execute liquidation through unstake
    let liquidated_balance = sponsor_pool::unstake(pool, position, liquidation_amount, ctx);
    let liquidated_amount = liquidated_balance.value();

    // Calculate fees and rewards
    let penalty_amount = liquidated_amount * LIQUIDATION_PENALTY_BPS / 10000;
    let keeper_reward_amount = liquidated_amount * LIQUIDATION_REWARD_BPS / 10000;
    let protocol_fee_amount = liquidated_amount * LIQUIDATION_PROTOCOL_BPS / 10000;
    let remaining_amount =
        liquidated_amount - penalty_amount - keeper_reward_amount - protocol_fee_amount;

    // Split balance for distribution
    let mut liquidated_balance = liquidated_balance;
    let keeper_reward = balance::split(&mut liquidated_balance, keeper_reward_amount);
    let protocol_fee = balance::split(&mut liquidated_balance, protocol_fee_amount);
    let penalty = balance::split(&mut liquidated_balance, penalty_amount);

    // Send keeper reward
    if (keeper_reward_amount > 0) {
        let keeper_coin = coin::from_balance(keeper_reward, ctx);
        transfer::public_transfer(keeper_coin, keeper::operator(keeper));
    } else {
        balance::destroy_zero(keeper_reward);
    };

    // Send protocol fee to treasury (add to pool for now)
    sponsor_pool::add_sui_balance(pool, protocol_fee);

    // Add penalty back to pool as compensation
    sponsor_pool::add_sui_balance(pool, penalty);

    // Update keeper statistics
    keeper::update_stats(
        keeper,
        keeper_cap,
        true, // success
        keeper_reward_amount as u128,
        gas_debt,
        timestamp_ms,
    );

    // Emit liquidation event
    event::emit(LiquidationEvent {
        position_id,
        liquidator: tx_context::sender(ctx),
        keeper_id: object::id(keeper),
        liquidation_amount: liquidated_amount,
        penalty_amount,
        keeper_reward: keeper_reward_amount,
        protocol_fee: protocol_fee_amount,
        timestamp: timestamp_ms,
    });

    // Return remaining liquidated assets to liquidator
    coin::from_balance(liquidated_balance, ctx)
}

/// Check if a position is liquidatable
/// * `pool`: The sponsor pool containing the position
/// * `position`: The position to check
/// * Returns (is_liquidatable, gas_debt_ratio)
public fun check_liquidatable<RewardCoin>(
    pool: &SponsorPool<RewardCoin>,
    position: &Position,
): (bool, u128) {
    let position_shares = position::shares(position);
    if (position_shares == 0) {
        return (false, 0)
    };

    let acc_gas_per_share = pool.acc_gas_per_share();
    let position_info = pool.get_position_info(object::id(position));

    let accumulated_gas = position_shares * acc_gas_per_share;
    let gas_debt = position_info.gas_debt_amount();

    let gas_debt_ratio = if (accumulated_gas > 0) {
        gas_debt * 10000 / accumulated_gas
    } else { 0 };

    // Position is liquidatable if gas debt exceeds 90% of accumulated gas
    let liquidatable = gas_debt_ratio >= 9000;

    (liquidatable, gas_debt_ratio)
}

/// Get liquidation info for a position
/// * `pool`: The sponsor pool containing the position
/// * `position`: The position to get info for
/// Returns (max_liquidation_amount, penalty_amount, keeper_reward, protocol_fee)
public fun get_liquidation_info<RewardCoin>(
    pool: &SponsorPool<RewardCoin>,
    position: &Position,
): (u64, u64, u64, u64) {
    let position_shares = position::shares(position) as u64;
    let max_liquidation_amount = position_shares * (MAX_LIQUIDATION_RATIO as u64) / 10000;

    let penalty_amount = max_liquidation_amount * LIQUIDATION_PENALTY_BPS / 10000;
    let keeper_reward = max_liquidation_amount * LIQUIDATION_REWARD_BPS / 10000;
    let protocol_fee = max_liquidation_amount * LIQUIDATION_PROTOCOL_BPS / 10000;

    (max_liquidation_amount, penalty_amount, keeper_reward, protocol_fee)
}
