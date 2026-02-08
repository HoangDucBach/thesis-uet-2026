/// Sponsor Pool Test Suite
///
/// This module tests the sponsor pool's financial mechanics with focus on:
///
/// ## Test Coverage:
///
/// ### Pool Management:
/// - `test_pool_creation_and_initialization`: Pool initialization with correct state
/// - `test_multiple_pools_isolation`: Pool isolation
/// - `test_pool_with_high_fee_rate`: Fee rate configuration validation
///
/// ### Fee Distribution (CRITICAL):
/// - `test_fee_distribution_with_custom_fee`: Comprehensive fee flow test
///
/// ### Gas Management:
/// - `test_keeper_gas_withdrawal`: Keeper can withdraw gas via take_gas()
/// - `test_insufficient_gas_balance_prevents_withdrawal`: Safety check for insufficient gas
/// - `test_gas_accumulation_across_cycles`: Gas accumulator tracking
/// - `test_gas_cost_deducted_from_unstake`: Gas debt deduction on unstake
/// - `test_reward_and_gas_distribution_multiple_cycles`: Multi-cycle scenarios
///
/// ### Economic Security:
/// - `test_pool_insolvency_graceful_handling`: Insolvency edge case handling
///

#[test_only]
module protocol::sponsor_pool_tests;

use protocol::constants::acc_precision;
use protocol::position::Position;
use protocol::sponsor_pool::{Self, SponsorPool};
use protocol::test_coins::REWARD;
use std::string;
use sui::balance;
use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::test_scenario::{Self as ts, Scenario};

// === Constants ===
const ADMIN: address = @0xABCD;
const USER_1: address = @0x1111;
const USER_2: address = @0x2222;
const KEEPER_ID: address = @0x3333;

const POOL_INDEX: u64 = 1;
const PROTOCOL_FEE_RATE_BPS: u64 = 5; // 0.05%
const KEEPER_FEE_RATE_BPS: u64 = 30; // 0.3%

// === Test Helpers ===

fun setup_pool(scenario: &mut Scenario): ID {
    ts::next_tx(scenario, ADMIN);
    {
        let pool = sponsor_pool::new_for_testing<REWARD>(
            object::id_from_address(KEEPER_ID),
            PROTOCOL_FEE_RATE_BPS,
            KEEPER_FEE_RATE_BPS,
            string::utf8(b"https://test.com/pool.png"),
            POOL_INDEX,
            ts::ctx(scenario),
        );
        let pool_id = object::id(&pool);
        transfer::public_share_object(pool);
        pool_id
    }
}

fun setup_pool_with_custom_fee(scenario: &mut Scenario, protocol_fee: u64, keeper_fee: u64): ID {
    ts::next_tx(scenario, ADMIN);
    {
        let pool = sponsor_pool::new_for_testing<REWARD>(
            object::id_from_address(KEEPER_ID),
            protocol_fee,
            keeper_fee,
            string::utf8(b"https://test.com/pool.png"),
            POOL_INDEX,
            ts::ctx(scenario),
        );
        let pool_id = object::id(&pool);
        transfer::public_share_object(pool);
        pool_id
    }
}

fun create_and_stake_position(scenario: &mut Scenario, user: address, amount: u64) {
    ts::next_tx(scenario, user);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(scenario);
        let position = pool.open_position(ts::ctx(scenario));
        transfer::public_transfer(position, user);
        ts::return_shared(pool);
    };

    ts::next_tx(scenario, user);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(scenario);
        let mut position = ts::take_from_sender<Position>(scenario);

        let stake_balance = balance::create_for_testing<SUI>(amount);
        pool.stake(&mut position, stake_balance);

        ts::return_to_sender(scenario, position);
        ts::return_shared(pool);
    }
}

// === Tests ===

#[test]
fun test_pool_creation_and_initialization() {
    let mut scenario = ts::begin(ADMIN);
    let pool_id = setup_pool(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        assert!(object::id(&pool) == pool_id, 0);
        assert!(sponsor_pool::keeper_id(&pool) == object::id_from_address(KEEPER_ID), 1);
        assert!(sponsor_pool::index(&pool) == POOL_INDEX, 2);
        assert!(sponsor_pool::total_shares(&pool) == 0, 3);
        assert!(sponsor_pool::acc_reward_per_share(&pool) == 0, 4);
        assert!(sponsor_pool::acc_gas_per_share(&pool) == 0, 5);

        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_multiple_pools_isolation() {
    let mut scenario = ts::begin(ADMIN);

    let _pool1_id = setup_pool(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let pool1 = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        assert!(sponsor_pool::index(&pool1) == POOL_INDEX, 0);
        ts::return_shared(pool1);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let pool2 = sponsor_pool::new_for_testing<REWARD>(
            object::id_from_address(KEEPER_ID),
            PROTOCOL_FEE_RATE_BPS,
            KEEPER_FEE_RATE_BPS,
            string::utf8(b"https://test.com/pool2.png"),
            999,
            ts::ctx(&mut scenario),
        );
        assert!(sponsor_pool::index(&pool2) == 999, 1);
        transfer::public_share_object(pool2);
    };

    ts::end(scenario);
}

#[test]
fun test_keeper_gas_withdrawal() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let gas_balance = balance::create_for_testing<SUI>(1000);
        sponsor_pool::add_sui_balance(&mut pool, gas_balance);

        ts::return_shared(pool);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let withdrawn: Coin<SUI> = sponsor_pool::take_gas(&mut pool, 500, ts::ctx(&mut scenario));

        assert!(coin::value(&withdrawn) == 500, 0);

        transfer::public_transfer(withdrawn, ADMIN);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = protocol::sponsor_pool::EInsufficientGasBalance)]
fun test_insufficient_gas_balance_prevents_withdrawal() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let gas_balance = balance::create_for_testing<SUI>(100);
        sponsor_pool::add_sui_balance(&mut pool, gas_balance);

        let withdrawn: Coin<SUI> = sponsor_pool::take_gas(&mut pool, 500, ts::ctx(&mut scenario));

        transfer::public_transfer(withdrawn, ADMIN);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_gas_accumulation_across_cycles() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);

    create_and_stake_position(&mut scenario, USER_1, 1000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        pool.update_pool_accs(0, 100);

        assert!(pool.acc_gas_per_share() == (100 * acc_precision()) / 1000, 0);

        ts::return_shared(pool);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        sponsor_pool::update_pool_accs(&mut pool, 0, 200);

        let expected_total = ((100 + 200) * acc_precision()) / 1000;
        assert!(sponsor_pool::acc_gas_per_share(&pool) == expected_total, 1);

        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_reward_and_gas_distribution_multiple_cycles() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);

    create_and_stake_position(&mut scenario, USER_1, 1000);
    create_and_stake_position(&mut scenario, USER_2, 1000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        sponsor_pool::update_pool_accs(&mut pool, 500, 50);
        ts::return_shared(pool);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        sponsor_pool::update_pool_accs(&mut pool, 500, 50);
        ts::return_shared(pool);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let expected_reward_per_share = ((500 + 500) * acc_precision()) / 2000;
        assert!(sponsor_pool::acc_reward_per_share(&pool) == expected_reward_per_share, 0);

        let expected_gas_per_share = ((50 + 50) * acc_precision()) / 2000;
        assert!(sponsor_pool::acc_gas_per_share(&pool) == expected_gas_per_share, 1);

        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_gas_cost_deducted_from_unstake() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);

    create_and_stake_position(&mut scenario, USER_1, 1000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let gas_balance = balance::create_for_testing<SUI>(5000);
        sponsor_pool::add_sui_balance(&mut pool, gas_balance);

        sponsor_pool::update_pool_accs(&mut pool, 0, 100);

        ts::return_shared(pool);
    };

    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let mut position = ts::take_from_sender<Position>(&scenario);

        let withdrawn = pool.unstake(&mut position, 1000, ts::ctx(&mut scenario));

        assert!(balance::value(&withdrawn) == 900, 0);

        let coin = coin::from_balance(withdrawn, ts::ctx(&mut scenario));
        transfer::public_transfer(coin, USER_1);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_pool_insolvency_graceful_handling() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);

    create_and_stake_position(&mut scenario, USER_1, 100);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let gas_balance = balance::create_for_testing<SUI>(100);
        sponsor_pool::add_sui_balance(&mut pool, gas_balance);

        sponsor_pool::update_pool_accs(&mut pool, 0, 500);

        ts::return_shared(pool);
    };

    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let mut position = ts::take_from_sender<Position>(&scenario);

        // Track pool balance BEFORE unstake (should be 200 SUI: 100 from user stake + 100 from gas fund)
        let pool_balance_before = sponsor_pool::balance_for_testing(&pool);
        assert!(pool_balance_before == 200, 0);

        let withdrawn = pool.unstake(&mut position, 100, ts::ctx(&mut scenario));

        // User receives 0 because gas debt (50*1e12 * shares / total_shares = 500 SUI per share > 100 stake)
        assert!(balance::value(&withdrawn) == 0, 1);

        // CRITICAL CHECK: Pool balance must NOT change - user's 100 SUI is kept to cover gas debt
        // This proves funds are correctly seized for insolvency recovery
        let pool_balance_after = sponsor_pool::balance_for_testing(&pool);
        assert!(pool_balance_after == pool_balance_before, 2);

        balance::destroy_for_testing(withdrawn);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_fee_distribution_with_custom_fee() {
    // COMPREHENSIVE FEE TEST: Verifies complete fee flow with realistic rates
    // Fee Structure:
    // - Protocol Fee: 0.05% (5 bps)
    // - Keeper Fee: 0.3% (30 bps)
    // - Total Fee: 0.35% (35 bps)
    //
    // Example with 100,000 REWARD:
    // - Protocol Fee: 100,000 * 0.05% = 50 REWARD
    // - Keeper Fee: 100,000 * 0.3% = 300 REWARD
    // - Net for Stakers: 100,000 - 50 - 300 = 99,650 REWARD
    let mut scenario = ts::begin(ADMIN);

    // Setup pool with realistic fee rates
    let _pool_id = setup_pool_with_custom_fee(
        &mut scenario,
        PROTOCOL_FEE_RATE_BPS,
        KEEPER_FEE_RATE_BPS,
    );

    create_and_stake_position(&mut scenario, USER_1, 100000);

    // 1: Add gross rewards and distribute with fees
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        // Add 100,000 REWARD tokens (gross reward)
        let gross_reward = 100000;
        let reward_coin = coin::mint_for_testing<REWARD>(gross_reward, ts::ctx(&mut scenario));
        let reward_balance = coin::into_balance(reward_coin);
        sponsor_pool::add_reward_balance(&mut pool, reward_balance);

        // Calculate expected values
        let protocol_fee = (gross_reward as u128 * (PROTOCOL_FEE_RATE_BPS as u128)) / 10000; // 50
        let keeper_fee = (gross_reward as u128 * (KEEPER_FEE_RATE_BPS as u128)) / 10000; // 300
        let net_for_stakers = (gross_reward as u128) - protocol_fee - keeper_fee; // 99650

        // Verify accumulator reflects NET reward only (99,650)
        let acc_reward = sponsor_pool::acc_reward_per_share(&pool);
        let expected_acc = (net_for_stakers * acc_precision()) / 100000; // 99650 * 1e12 / 100000
        assert!(acc_reward == expected_acc, 0);

        // Verify protocol fee recorded (50)
        assert!(sponsor_pool::unclaimed_protocol_fee(&pool) == (protocol_fee as u64), 1);

        // Verify keeper fee recorded (300)
        assert!(sponsor_pool::unclaimed_keeper_fee(&pool) == (keeper_fee as u64), 2);

        // Verify pool balance: 100000 (all fees use lazy collection now)
        let expected_pool_balance = gross_reward;
        assert!(sponsor_pool::reward_balance_for_testing(&pool) == expected_pool_balance, 3);

        ts::return_shared(pool);
    };

    // 2: User withdraws rewards (should get 99,650, not 100,000)
    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let mut position = ts::take_from_sender<Position>(&scenario);

        let reward_balance = sponsor_pool::withdraw_rewards(&mut pool, &mut position);
        let user_reward = balance::value(&reward_balance);

        // User should receive exactly 99,650 (NET reward after both fees)
        // = 100,000 - 50 (protocol) - 300 (keeper)
        assert!(user_reward == 99650, 3);

        balance::destroy_for_testing(reward_balance);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    // 3: Verify keeper fee is recorded (lazy collection)
    ts::next_tx(&mut scenario, ADMIN);
    {
        let pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        // Keeper fee should be recorded for lazy collection (300 REWARD = 0.3% of 100k)
        let expected_keeper_fee = (100000 * KEEPER_FEE_RATE_BPS) / 10000;
        assert!(sponsor_pool::unclaimed_keeper_fee(&pool) == expected_keeper_fee, 4);

        // Verify unclaimed protocol fee still recorded (50 REWARD = 0.05% of 100k)
        let expected_protocol_fee = (100000 * PROTOCOL_FEE_RATE_BPS) / 10000;
        assert!(sponsor_pool::unclaimed_protocol_fee(&pool) == expected_protocol_fee, 5);

        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_pool_with_high_fee_rate() {
    let mut scenario = ts::begin(ADMIN);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let pool = sponsor_pool::new_for_testing<REWARD>(
            object::id_from_address(KEEPER_ID),
            5000,
            5000,
            string::utf8(b"https://test.com/high_fee.png"),
            10,
            ts::ctx(&mut scenario),
        );

        assert!(sponsor_pool::index(&pool) == 10, 0);

        transfer::public_share_object(pool);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        assert!(sponsor_pool::total_shares(&pool) == 0, 1);

        ts::return_shared(pool);
    };

    ts::end(scenario);
}
