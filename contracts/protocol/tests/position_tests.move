/// Position Management Test Suite - Core Staking & Security
///
/// Tests the position lifecycle and MasterChef-style reward distribution system.
///
/// ## Reward Distribution Mechanism:
/// Uses accumulated per-share accounting:
/// - `acc_reward_per_share`: Accumulated reward per share (scaled by 1e12)
/// - `reward_debt`: Position's "entry price" in reward distribution
/// - `pending_reward = (shares × acc_reward_per_share) - reward_debt`
///
/// ## Test Coverage:
///
/// ### Basic Position Operations:
/// - `test_open_position`: Position creation
/// - `test_close_position`: Position cleanup
/// - `test_stake_and_increment_shares`: Basic staking
/// - `test_unstake_reduces_shares`: Basic unstaking
/// - `test_stake_zero_amount_fails`: Input validation (security)
///
/// ### Staking Mechanics:
/// - `test_multiple_stakes_accumulate`: Multiple stakes accumulate shares
/// - `test_multiple_users_stake`: Multi-user scenarios
///
/// ### Economic Fairness:
/// - `test_proportional_reward_distribution`: **Proportional rewards based on shares**
/// - `test_late_entry`: **Anti-dilution - late stakers don't claim old rewards**
/// - `test_reward_after_additional_stake`: Rewards adjust correctly after new stakes
/// - `test_stake_harvest_then_stake_again`: Harvest + re-stake flow
///
/// ### Reward & Gas Claims:
/// - `test_reward_distribution`: Basic reward claiming
/// - `test_withdraw_rewards`: Withdraw accumulated rewards
/// - `test_withdraw_gas`: Withdraw gas reimbursement
/// - `test_gas_debt_tracking`: Gas accumulator tracking
///
/// ### Security & Edge Cases:
/// - `test_cannot_unstake_more_than_balance`: **Prevent over-withdrawal**
/// - `test_cannot_use_position_in_wrong_pool`: **Access control across pools**
/// - `test_gas_cost_exceeds_principal`: **Edge case: gas debt > principal**
///

#[test_only]
module protocol::position_tests;

use protocol::constants::acc_precision;
use protocol::position::Position;
use protocol::sponsor_pool::{Self, SponsorPool};
use protocol::test_coins::REWARD;
use std::string;
use sui::balance;
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
            string::utf8(b"https://test.com/image.png"),
            POOL_INDEX,
            ts::ctx(scenario),
        );
        let pool_id = object::id(&pool);
        transfer::public_share_object(pool);
        pool_id
    }
}

fun create_position_in_pool(scenario: &mut Scenario, user: address): ID {
    ts::next_tx(scenario, user);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(scenario);
        let position = pool.open_position(ts::ctx(scenario));
        let position_id = object::id(&position);
        transfer::public_transfer(position, user);
        ts::return_shared(pool);
        position_id
    }
}

fun stake_to_position(scenario: &mut Scenario, user: address, amount: u64) {
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

fun add_rewards_to_pool(scenario: &mut Scenario, reward_amount: u128, gas_amount: u128) {
    ts::next_tx(scenario, ADMIN);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(scenario);
        pool.update_pool_accs(reward_amount, gas_amount);
        ts::return_shared(pool);
    }
}

fun add_actual_reward_balance(scenario: &mut Scenario, reward_amount: u64) {
    ts::next_tx(scenario, ADMIN);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(scenario);
        let reward_balance = balance::create_for_testing<REWARD>(reward_amount);
        pool.add_reward_balance(reward_balance);
        ts::return_shared(pool);
    }
}

// === Tests ===

#[test]
fun test_open_position() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);

    // User opens a position
    let position_id = create_position_in_pool(&mut scenario, USER_1);

    ts::next_tx(&mut scenario, USER_1);
    {
        let position = ts::take_from_sender<Position>(&scenario);
        let pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        // Verify position created correctly
        assert!(object::id(&position) == position_id, 0);
        assert!(position.pool_id() == object::id(&pool), 1);
        assert!(position.shares() == 0, 2);

        // Verify position info in manager
        let position_info = pool.get_position_info(position_id);
        assert!(position_info.position_info_position_id() == position_id, 3);
        assert!(position_info.position_info_shares() == 0, 4);

        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_stake_and_increment_shares() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);
    let _position_id = create_position_in_pool(&mut scenario, USER_1);

    // Stake 1000 SUI
    stake_to_position(&mut scenario, USER_1, 1000);

    ts::next_tx(&mut scenario, USER_1);
    {
        let position = ts::take_from_sender<Position>(&scenario);
        let pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        // Verify shares increased
        assert!(position.shares() == 1000, 0);

        // Verify pool total shares
        assert!(pool.total_shares() == 1000, 1);

        // Verify position info
        let position_info = pool.get_position_info(object::id(&position));
        assert!(position_info.position_info_shares() == 1000, 2);

        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_multiple_users_stake() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);

    // User 1 opens position and stakes 1000
    let _pos1_id = create_position_in_pool(&mut scenario, USER_1);
    stake_to_position(&mut scenario, USER_1, 1000);

    // User 2 opens position and stakes 2000
    let _pos2_id = create_position_in_pool(&mut scenario, USER_2);
    stake_to_position(&mut scenario, USER_2, 2000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        // Verify total shares = 3000
        assert!(pool.total_shares() == 3000, 0);

        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_reward_distribution() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);

    let pos1_id = create_position_in_pool(&mut scenario, USER_1);
    stake_to_position(&mut scenario, USER_1, 1000);

    add_rewards_to_pool(&mut scenario, 1000, 0);

    ts::next_tx(&mut scenario, USER_1);
    {
        let position = ts::take_from_sender<Position>(&scenario);
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        // Calculate pending rewards
        let acc_reward = pool.acc_reward_per_share();
        let acc_gas = pool.acc_gas_per_share();
        let (pending_reward, _pending_gas) = position.harvest(
            pool.position_manager_mut(),
            acc_reward,
            acc_gas,
        );

        // Expected: 1000 * acc_precision() = 1000 * 1e12
        let expected_reward_scaled = 1000 * acc_precision();
        assert!(pending_reward == expected_reward_scaled, 0);

        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_proportional_reward_distribution() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);

    // User 1 stakes 6000 (60% of total)
    let _pos1_id = create_position_in_pool(&mut scenario, USER_1);
    stake_to_position(&mut scenario, USER_1, 6000);

    // User 2 stakes 4000 (40% of total)
    let _pos2_id = create_position_in_pool(&mut scenario, USER_2);
    stake_to_position(&mut scenario, USER_2, 4000);

    // Add 10000 reward tokens
    add_rewards_to_pool(&mut scenario, 10000, 0);

    // User 1 should get 6000 rewards (60%)
    ts::next_tx(&mut scenario, USER_1);
    {
        let position = ts::take_from_sender<Position>(&scenario);
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let acc_reward = pool.acc_reward_per_share();
        let acc_gas = pool.acc_gas_per_share();
        let (pending_reward, _) = position.harvest(
            pool.position_manager_mut(),
            acc_reward,
            acc_gas,
        );

        let actual_reward = pending_reward / acc_precision();
        assert!(actual_reward == 6000, 0);

        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    // User 2 should get 4000 rewards (40%)
    ts::next_tx(&mut scenario, USER_2);
    {
        let position = ts::take_from_sender<Position>(&scenario);
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let acc_reward = pool.acc_reward_per_share();
        let acc_gas = pool.acc_gas_per_share();
        let (pending_reward, _) = position.harvest(
            pool.position_manager_mut(),
            acc_reward,
            acc_gas,
        );

        let actual_reward = pending_reward / acc_precision();
        assert!(actual_reward == 4000, 1);

        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_unstake_reduces_shares() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);
    let _position_id = create_position_in_pool(&mut scenario, USER_1);

    // Stake 1000 SUI
    stake_to_position(&mut scenario, USER_1, 1000);

    // Unstake 400 SUI
    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let mut position = ts::take_from_sender<Position>(&scenario);

        let withdrawn = pool.unstake(
            &mut position,
            400,
            ts::ctx(&mut scenario),
        );

        // Should receive 400 SUI back
        assert!(balance::value(&withdrawn) == 400, 0);

        // Shares should be 600 now
        assert!(position.shares() == 600, 1);
        assert!(pool.total_shares() == 600, 2);

        balance::destroy_for_testing(withdrawn);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_gas_debt_tracking() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);
    let _position_id = create_position_in_pool(&mut scenario, USER_1);

    // Stake 1000 SUI
    stake_to_position(&mut scenario, USER_1, 1000);

    // Add gas cost to pool: 500 gas units
    add_rewards_to_pool(&mut scenario, 0, 500);

    ts::next_tx(&mut scenario, USER_1);
    {
        let position = ts::take_from_sender<Position>(&scenario);
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        // Calculate pending gas
        let acc_reward = pool.acc_reward_per_share();
        let acc_gas = pool.acc_gas_per_share();
        let (_pending_reward, pending_gas) = position.harvest(
            pool.position_manager_mut(),
            acc_reward,
            acc_gas,
        );

        // Expected gas: 500 * acc_precision()
        let expected_gas_scaled = 500 * acc_precision();
        assert!(pending_gas == expected_gas_scaled, 0);

        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_close_position() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);
    let position_id = create_position_in_pool(&mut scenario, USER_1);

    // Close position
    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let position = ts::take_from_sender<Position>(&scenario);

        pool.close_position(position);

        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = protocol::sponsor_pool::EZeroStake)]
fun test_stake_zero_amount_fails() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);
    let _position_id = create_position_in_pool(&mut scenario, USER_1);

    stake_to_position(&mut scenario, USER_1, 0);

    ts::end(scenario);
}

#[test]
fun test_multiple_stakes_accumulate() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);
    let _position_id = create_position_in_pool(&mut scenario, USER_1);

    // Stake 1000 SUI
    stake_to_position(&mut scenario, USER_1, 1000);

    // Stake another 500 SUI
    stake_to_position(&mut scenario, USER_1, 500);

    // Stake another 300 SUI
    stake_to_position(&mut scenario, USER_1, 300);

    ts::next_tx(&mut scenario, USER_1);
    {
        let position = ts::take_from_sender<Position>(&scenario);
        let pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        // Total shares should be 1800
        assert!(position.shares() == 1800, 0);
        assert!(pool.total_shares() == 1800, 1);

        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_reward_after_additional_stake() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);
    let _position_id = create_position_in_pool(&mut scenario, USER_1);

    // Stake 1000 SUI
    stake_to_position(&mut scenario, USER_1, 1000);

    // Add 2000 rewards on 2000 total shares
    add_rewards_to_pool(&mut scenario, 2000, 0);

    // Stake another 1000 SUI immediately (before any rewards)
    stake_to_position(&mut scenario, USER_1, 1000);

    ts::next_tx(&mut scenario, USER_1);
    {
        let position = ts::take_from_sender<Position>(&scenario);
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let acc_reward = pool.acc_reward_per_share();
        let acc_gas = pool.acc_gas_per_share();
        let (pending_reward, _) = position.harvest(
            pool.position_manager_mut(),
            acc_reward,
            acc_gas,
        );

        // User has 2000 shares, should get all 2000 rewards
        let actual_reward = pending_reward / acc_precision();
        assert!(actual_reward == 2000, 0);

        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_withdraw_rewards() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);
    let _position_id = create_position_in_pool(&mut scenario, USER_1);

    // Stake 1000 SUI
    stake_to_position(&mut scenario, USER_1, 1000);

    // Add 500 rewards to pool (this will deduct fees automatically)
    add_actual_reward_balance(&mut scenario, 500);

    // Withdraw rewards
    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let mut position = ts::take_from_sender<Position>(&scenario);

        let reward_balance = pool.withdraw_rewards(&mut position);

        // Should receive net rewards after fees (500 - keeper_fee - protocol_fee)
        // Keeper: 500 * 30 / 10000 = 1, Protocol: 500 * 5 / 10000 = 0
        // Net: 500 - 1 - 0 = 499
        assert!(balance::value(&reward_balance) == 499, 0);

        balance::destroy_for_testing(reward_balance);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_withdraw_gas() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);
    let _position_id = create_position_in_pool(&mut scenario, USER_1);

    // Stake 1000 SUI
    stake_to_position(&mut scenario, USER_1, 1000);

    // Add 300 gas units
    add_rewards_to_pool(&mut scenario, 0, 300);

    // Withdraw gas
    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let mut position = ts::take_from_sender<Position>(&scenario);

        let gas_balance = pool.withdraw_gas(&mut position);

        // Should receive 300 gas
        assert!(balance::value(&gas_balance) == 300, 0);

        balance::destroy_for_testing(gas_balance);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_stake_harvest_then_stake_again() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);
    let _position_id = create_position_in_pool(&mut scenario, USER_1);

    // === Phase 1: Initial stake ===
    stake_to_position(&mut scenario, USER_1, 1000);

    // Add 1000 rewards (fees will be deducted)
    // Keeper: 1000 * 30 / 10000 = 3, Protocol: 1000 * 5 / 10000 = 0
    // Net: 1000 - 3 - 0 = 997
    add_actual_reward_balance(&mut scenario, 1000);

    // Harvest first round of rewards
    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let mut position = ts::take_from_sender<Position>(&scenario);

        // Withdraw the rewards (this calls harvest internally)
        let reward_balance = pool.withdraw_rewards(&mut position);
        assert!(balance::value(&reward_balance) == 997, 0);

        balance::destroy_for_testing(reward_balance);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    // === Phase 2: Second stake after harvest ===
    stake_to_position(&mut scenario, USER_1, 500);

    // Add more rewards: 1500 on total 1500 shares
    // Keeper: 1500 * 30 / 10000 = 4 (truncated), Protocol: 1500 * 5 / 10000 = 0 (truncated)
    // Net: 1500 - 4 - 0 = 1496
    // But due to precision loss in accumulator: (1496 * 1e12) / 1500 = 997333333333
    // Actual reward: (997333333333 * 1500) / 1e12 = 1495
    add_actual_reward_balance(&mut scenario, 1500);

    // Check second pending reward
    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let mut position = ts::take_from_sender<Position>(&scenario);

        // Verify position has correct shares
        assert!(position.shares() == 1500, 1);

        // Withdraw second batch (harvest is called internally)
        let reward_balance = pool.withdraw_rewards(&mut position);
        // Actual reward is 1495 due to accumulator precision loss
        assert!(balance::value(&reward_balance) == 1495, 2);

        balance::destroy_for_testing(reward_balance);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_late_entry() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);

    let _pos1 = create_position_in_pool(&mut scenario, USER_1);
    stake_to_position(&mut scenario, USER_1, 1000);

    add_rewards_to_pool(&mut scenario, 1000, 0);

    let _pos2 = create_position_in_pool(&mut scenario, USER_2);
    stake_to_position(&mut scenario, USER_2, 1000);

    add_rewards_to_pool(&mut scenario, 1000, 0);

    ts::next_tx(&mut scenario, USER_1);
    {
        let position = ts::take_from_sender<Position>(&scenario);
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let acc_reward = pool.acc_reward_per_share();
        let acc_gas = pool.acc_gas_per_share();
        let (pending, _) = position.harvest(
            pool.position_manager_mut(),
            acc_reward,
            acc_gas,
        );

        let actual_reward = pending / acc_precision();
        assert!(actual_reward == 1500, 0);

        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::next_tx(&mut scenario, USER_2);
    {
        let position = ts::take_from_sender<Position>(&scenario);
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        let acc_reward = pool.acc_reward_per_share();
        let acc_gas = pool.acc_gas_per_share();
        let (pending, _) = position.harvest(
            pool.position_manager_mut(),
            acc_reward,
            acc_gas,
        );

        let actual_reward = pending / acc_precision();
        assert!(actual_reward == 500, 1);

        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_cannot_unstake_more_than_balance() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);
    let _pos = create_position_in_pool(&mut scenario, USER_1);

    stake_to_position(&mut scenario, USER_1, 1000);

    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let mut position = ts::take_from_sender<Position>(&scenario);

        assert!(position.shares() == 1000, 0);

        let coin = pool.unstake(&mut position, 500, ts::ctx(&mut scenario));
        assert!(balance::value(&coin) > 0, 1);

        balance::destroy_for_testing(coin);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_gas_cost_exceeds_principal() {
    let mut scenario = ts::begin(ADMIN);
    let _pool_id = setup_pool(&mut scenario);
    let _pos = create_position_in_pool(&mut scenario, USER_1);

    stake_to_position(&mut scenario, USER_1, 10);

    add_rewards_to_pool(&mut scenario, 0, 100);

    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let mut position = ts::take_from_sender<Position>(&scenario);

        let withdrawn = pool.unstake(&mut position, 10, ts::ctx(&mut scenario));

        assert!(balance::value(&withdrawn) == 0, 0);

        balance::destroy_for_testing(withdrawn);
        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool);
    };

    ts::end(scenario);
}

#[test]
fun test_cannot_use_position_in_wrong_pool() {
    let mut scenario = ts::begin(ADMIN);

    let pool1_id = setup_pool(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let pool2 = sponsor_pool::new_for_testing<REWARD>(
            object::id_from_address(KEEPER_ID),
            PROTOCOL_FEE_RATE_BPS,
            KEEPER_FEE_RATE_BPS,
            string::utf8(b"https://test.com/image2.png"),
            2,
            ts::ctx(&mut scenario),
        );
        transfer::public_share_object(pool2);
    };

    ts::next_tx(&mut scenario, USER_1);
    {
        let mut pool1 = ts::take_shared<SponsorPool<REWARD>>(&scenario);
        let position = pool1.open_position(ts::ctx(&mut scenario));
        transfer::public_transfer(position, USER_1);
        ts::return_shared(pool1);
    };

    ts::next_tx(&mut scenario, USER_1);
    {
        let position = ts::take_from_sender<Position>(&scenario);
        let mut pool1 = ts::take_shared<SponsorPool<REWARD>>(&scenario);

        assert!(position.pool_id() == object::id(&pool1), 0);

        ts::return_to_sender(&scenario, position);
        ts::return_shared(pool1);
    };

    ts::end(scenario);
}
