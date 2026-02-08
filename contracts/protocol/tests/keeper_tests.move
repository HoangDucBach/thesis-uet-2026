/// Keeper Test Suite
///
/// Tests critical keeper operations focusing on security and economic correctness.
/// These tests ensure the keeper system operates safely and fairly.
///
/// ### Economic Correctness:
/// 1. `test_keeper_fee_instant_payment` - Keeper receives 0.3% fee instantly
/// 2. `test_protocol_fee_lazy_collection` - Protocol 0.05% fee recorded
/// 3. `test_stakers_receive_net_rewards` - Stakers get 99.65% (gross - fees)
/// 4. `test_complete_keeper_execution_flow` - Full end-to-end flow
///
/// ### Security:
/// 5. test_only_keeper_owner_can_execute - Access control (TODO: needs keeper.move)
/// 6. test_execution_requires_valid_enclave_signature - TEE security (TODO: needs keeper.move)
///
/// ### Gas Management:
/// 7. `test_keeper_takes_gas_before_execution` - Gas withdrawal mechanics
/// 8. `test_insufficient_gas_prevents_execution` - Safety check
///
/// ## Fee Structure:
/// - Protocol Fee: 5 bps (0.05%) - Platform revenue
/// - Keeper Fee: 30 bps (0.3%) - Execution incentive
/// - Total: 35 bps (0.35%)

#[test_only]
module protocol::keeper_tests;

use protocol::config;
use protocol::keeper::{Self, Keeper, KeeperCap};
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
const KEEPER_ADDR: address = @0x3333;
const USER_1: address = @0x1111;

const POOL_INDEX: u64 = 1;
const PROTOCOL_FEE_RATE_BPS: u64 = 5; // 0.05%
const KEEPER_FEE_RATE_BPS: u64 = 30; // 0.3%

// === Test Helpers ===

fun setup_pool_with_keeper(scenario: &mut Scenario): (ID, ID) {
    ts::next_tx(scenario, ADMIN);
    {
        // Create global config
        let (admin_cap, global_config) = config::new_for_testing(ts::ctx(scenario));
        transfer::public_transfer(admin_cap, ADMIN);
        transfer::public_share_object(global_config);
    };

    ts::next_tx(scenario, ADMIN);
    {
        // Create keeper
        let (keeper, cap) = keeper::create_keeper_for_testing(
            KEEPER_ADDR,
            string::utf8(b"Test Keeper"),
            ts::ctx(scenario),
        );
        let keeper_id = object::id(&keeper);
        transfer::public_share_object(keeper);
        transfer::public_transfer(cap, KEEPER_ADDR);

        // Create pool
        let pool = sponsor_pool::new_for_testing<REWARD>(
            keeper_id,
            PROTOCOL_FEE_RATE_BPS,
            KEEPER_FEE_RATE_BPS,
            string::utf8(b"https://keeper.pool/image.png"),
            POOL_INDEX,
            ts::ctx(scenario),
        );
        let pool_id = object::id(&pool);
        transfer::public_share_object(pool);

        (pool_id, keeper_id)
    }
}

fun create_position_and_stake(scenario: &mut Scenario, user: address, amount: u64) {
    ts::next_tx(scenario, user);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(scenario);
        let position = sponsor_pool::open_position(&mut pool, ts::ctx(scenario));
        transfer::public_transfer(position, user);
        ts::return_shared(pool);
    };

    ts::next_tx(scenario, user);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(scenario);
        let mut position = ts::take_from_sender<Position>(scenario);
        let stake_balance = balance::create_for_testing<SUI>(amount);
        sponsor_pool::stake(&mut pool, &mut position, stake_balance);
        ts::return_to_sender(scenario, position);
        ts::return_shared(pool);
    }
}

// === Economic Tests ===

#[test]
fun test_keeper_fee_instant_payment() {
    let mut scenario = ts::begin(ADMIN);
    let (_pool_id, _keeper_id) = setup_pool_with_keeper(&mut scenario);

    create_position_and_stake(&mut scenario, USER_1, 100_000);

    // Keeper executes and distributes rewards
    ts::next_tx(&mut scenario, KEEPER_ADDR);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        // Add gross rewards to pool - accounts for fees automatically
        let gross_reward = 100_000u64;
        let reward_balance = balance::create_for_testing<REWARD>(gross_reward);
        sponsor_pool::add_reward_balance(&mut pool, reward_balance);

        ts::return_shared(pool);
    };

    // Keeper collects fee
    ts::next_tx(&mut scenario, KEEPER_ADDR);
    {
        let config = ts::take_shared<config::GlobalConfig>(&scenario);
        let keeper = ts::take_shared<Keeper>(&scenario);
        let cap = ts::take_from_sender<KeeperCap>(&scenario);
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let keeper_fee_balance = sponsor_pool::collect_keeper_fee(
            &config,
            &mut pool,
            &keeper,
            &cap,
        );
        let expected_keeper_fee = (100_000 * KEEPER_FEE_RATE_BPS) / 10_000; // 300
        assert!(balance::value(&keeper_fee_balance) == expected_keeper_fee, 0);

        balance::destroy_for_testing(keeper_fee_balance);
        ts::return_to_sender(&scenario, cap);
        ts::return_shared(keeper);
        ts::return_shared(pool);
        ts::return_shared(config);
    };

    ts::end(scenario);
}

#[test]
fun test_protocol_fee_lazy_collection() {
    // Test: Protocol fee recorded
    // Setup: 100k staked, 100k reward execution
    // Expected: Protocol fee 50 REWARD recorded in unclaimed_protocol_fee
    let mut scenario = ts::begin(ADMIN);
    let (_pool_id, _keeper_id) = setup_pool_with_keeper(&mut scenario);

    create_position_and_stake(&mut scenario, USER_1, 100_000);

    // Execute and distribute
    ts::next_tx(&mut scenario, KEEPER_ADDR);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let gross_reward = 100_000u64;
        let reward_balance = balance::create_for_testing<REWARD>(gross_reward);
        sponsor_pool::add_reward_balance(&mut pool, reward_balance);

        // Verify protocol fee recorded
        let expected_protocol_fee = (100_000 * PROTOCOL_FEE_RATE_BPS) / 10_000; // 50
        assert!(sponsor_pool::unclaimed_protocol_fee(&pool) == expected_protocol_fee, 1);

        // Verify fee still in pool balance
        let pool_balance = sponsor_pool::reward_balance_for_testing(&pool);
        // Pool has: keeper_fee (300) + protocol_fee (50) + staker_rewards (99650) = 100000
        assert!(pool_balance == 100_000, 2);

        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_stakers_receive_net_rewards() {
    // Test: Stakers receive NET rewards (gross - keeper_fee - protocol_fee)
    // Setup: 100k staked, 100k reward execution
    // Expected: Staker withdraws 99,650 REWARD (99.65% of gross)
    let mut scenario = ts::begin(ADMIN);
    let (_pool_id, _keeper_id) = setup_pool_with_keeper(&mut scenario);

    create_position_and_stake(&mut scenario, USER_1, 100_000);

    // Execute and distribute
    ts::next_tx(&mut scenario, KEEPER_ADDR);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let gross_reward = 100_000u64;
        let reward_balance = balance::create_for_testing<REWARD>(gross_reward);
        sponsor_pool::add_reward_balance(&mut pool, reward_balance);

        ts::return_shared(pool);
    };

    // User withdraws rewards
    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let mut position = ts::take_from_sender<Position>(&scenario);

        let reward_balance = sponsor_pool::withdraw_rewards(&mut pool, &mut position);
        let user_reward = balance::value(&reward_balance);

        // Expected: 100,000 - 300 (keeper) - 50 (protocol) = 99,650
        let expected_net = 100_000 - 300 - 50;
        assert!(user_reward == expected_net, 3);

        balance::destroy_for_testing(reward_balance);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_complete_keeper_execution_flow() {
    // Test: Complete end-to-end keeper execution cycle
    // Flow: Take gas → Execute → Distribute rewards → Verify all parties
    let mut scenario = ts::begin(ADMIN);
    let (_pool_id, _keeper_id) = setup_pool_with_keeper(&mut scenario);

    create_position_and_stake(&mut scenario, USER_1, 100_000);

    // 1: Keeper takes gas for execution
    ts::next_tx(&mut scenario, KEEPER_ADDR);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let gas_needed = 1_000u64;
        let gas_coin = sponsor_pool::take_gas(&mut pool, gas_needed, ts::ctx(&mut scenario));

        // Verify gas taken
        assert!(coin::value(&gas_coin) == gas_needed, 0);

        transfer::public_transfer(gas_coin, KEEPER_ADDR);
        ts::return_shared(pool);
    };

    // 2: Keeper executes task and gets reward (simulated)
    let execution_result = 100_000u64; // Gross reward from execution

    // 3: Keeper distributes rewards with fee handling
    ts::next_tx(&mut scenario, KEEPER_ADDR);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        // Add execution result to pool
        let reward_balance = balance::create_for_testing<REWARD>(execution_result);
        sponsor_pool::add_reward_balance(&mut pool, reward_balance);

        ts::return_shared(pool);
    };

    // 4: Keeper collects gas + fee
    ts::next_tx(&mut scenario, KEEPER_ADDR);
    {
        let config = ts::take_shared<config::GlobalConfig>(&scenario);
        let keeper = ts::take_shared<Keeper>(&scenario);
        let cap = ts::take_from_sender<KeeperCap>(&scenario);
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        // Gas coin
        let gas_coin = ts::take_from_sender<Coin<SUI>>(&scenario);
        assert!(coin::value(&gas_coin) == 1_000, 1);

        // Keeper collects fee balance
        let keeper_fee_balance = sponsor_pool::collect_keeper_fee(
            &config,
            &mut pool,
            &keeper,
            &cap,
        );
        assert!(balance::value(&keeper_fee_balance) == 300, 2);

        balance::destroy_for_testing(keeper_fee_balance);
        ts::return_to_sender(&scenario, gas_coin);
        ts::return_to_sender(&scenario, cap);
        ts::return_shared(keeper);
        ts::return_shared(pool);
        ts::return_shared(config);
    };

    // 5: Verify protocol fee recorded
    ts::next_tx(&mut scenario, ADMIN);
    {
        let pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        assert!(sponsor_pool::unclaimed_protocol_fee(&pool) == 50, 3);
        ts::return_shared(pool);
    };

    // Step 6: Verify staker can withdraw net rewards
    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let mut position = ts::take_from_sender<Position>(&scenario);

        let reward_balance = sponsor_pool::withdraw_rewards(&mut pool, &mut position);
        assert!(balance::value(&reward_balance) == 99_650, 4);

        balance::destroy_for_testing(reward_balance);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

// === Gas Management Tests ===

#[test]
fun test_keeper_takes_gas_before_execution() {
    // Test: Keeper can withdraw gas from pool before execution
    // Expected: Gas taken successfully, pool balance reduced
    let mut scenario = ts::begin(ADMIN);
    let (_pool_id, _keeper_id) = setup_pool_with_keeper(&mut scenario);

    create_position_and_stake(&mut scenario, USER_1, 10_000);

    ts::next_tx(&mut scenario, KEEPER_ADDR);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let initial_balance = sponsor_pool::balance_for_testing(&pool);
        let gas_amount = 1_000u64;

        let gas_coin = sponsor_pool::take_gas(&mut pool, gas_amount, ts::ctx(&mut scenario));

        // Verify gas coin value
        assert!(coin::value(&gas_coin) == gas_amount, 0);

        // Verify pool balance reduced
        let final_balance = sponsor_pool::balance_for_testing(&pool);
        assert!(final_balance == initial_balance - gas_amount, 1);

        transfer::public_transfer(gas_coin, KEEPER_ADDR);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = sponsor_pool::EInsufficientGasBalance)]
fun test_insufficient_gas_prevents_execution() {
    // Test: Keeper cannot take more gas than pool has
    // Expected: Abort with EInsufficientGasBalance
    let mut scenario = ts::begin(ADMIN);
    let (_pool_id, _keeper_id) = setup_pool_with_keeper(&mut scenario);

    create_position_and_stake(&mut scenario, USER_1, 1_000);

    ts::next_tx(&mut scenario, KEEPER_ADDR);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        // Try to take more gas than available
        let excessive_gas = 10_000u64; // Pool only has 1000
        let gas_coin = sponsor_pool::take_gas(&mut pool, excessive_gas, ts::ctx(&mut scenario));

        transfer::public_transfer(gas_coin, KEEPER_ADDR);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}
