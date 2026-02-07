#[test_only]
module protocol::test_coins;

use sui::coin::{Self, Coin, TreasuryCap};
use sui::coin_registry::{Self, MetadataCap};
use sui::package;

// === Test Coins ===
public struct TEST_COINS has drop {}

/// Test USDC coin for protocol testing
public struct TEST_USDC has drop {}

/// Test USDT coin for protocol testing
public struct TEST_USDT has drop {}

/// Test WETH coin for protocol testing
public struct TEST_WETH has drop {}

/// Reward token for testing
public struct REWARD has drop {}

fun init(otw: TEST_COINS, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);
    let (usdc_treasury, usdc_metadata_cap) = create_test_usdc(ctx);
    let (usdt_treasury, usdt_metadata_cap) = create_test_usdt(ctx);
    let (weth_treasury, weth_metadata_cap) = create_test_weth(ctx);
    let (reward_treasury, reward_metadata_cap) = create_test_reward(ctx);

    transfer::public_transfer(publisher, ctx.sender());
    transfer::public_transfer(usdc_metadata_cap, ctx.sender());
    transfer::public_transfer(usdc_treasury, ctx.sender());
    transfer::public_transfer(usdt_metadata_cap, ctx.sender());
    transfer::public_transfer(usdt_treasury, ctx.sender());
    transfer::public_transfer(weth_metadata_cap, ctx.sender());
    transfer::public_transfer(weth_treasury, ctx.sender());
    transfer::public_transfer(reward_metadata_cap, ctx.sender());
    transfer::public_transfer(reward_treasury, ctx.sender());
}
// === Coin Creation ===

/// Create test USDC coins for testing
public fun create_test_usdc(ctx: &mut TxContext): (TreasuryCap<TEST_USDC>, MetadataCap<TEST_USDC>) {
    let (builder, treasury_cap) = coin_registry::new_currency_with_otw<TEST_USDC>(
        TEST_USDC {},
        6,
        b"USDC".to_string(),
        b"USD Coin".to_string(),
        b"Test USDC for protocol".to_string(),
        b"".to_string(),
        ctx,
    );

    let metadata_cap = builder.finalize(ctx);
    (treasury_cap, metadata_cap)
}

/// Create test USDT coins for testing
public fun create_test_usdt(ctx: &mut TxContext): (TreasuryCap<TEST_USDT>, MetadataCap<TEST_USDT>) {
    let (builder, treasury_cap) = coin_registry::new_currency_with_otw<TEST_USDT>(
        TEST_USDT {},
        6,
        b"USDT".to_string(),
        b"Tether USD".to_string(),
        b"Test USDT for protocol".to_string(),
        b"".to_string(),
        ctx,
    );

    let metadata_cap = builder.finalize(ctx);
    (treasury_cap, metadata_cap)
}

/// Create test WETH coins for testing
public fun create_test_weth(ctx: &mut TxContext): (TreasuryCap<TEST_WETH>, MetadataCap<TEST_WETH>) {
    let (builder, treasury_cap) = coin_registry::new_currency_with_otw<TEST_WETH>(
        TEST_WETH {},
        18,
        b"WETH".to_string(),
        b"Wrapped Ether".to_string(),
        b"Test WETH for protocol".to_string(),
        b"".to_string(),
        ctx,
    );

    let metadata_cap = builder.finalize(ctx);
    (treasury_cap, metadata_cap)
}

/// Create test REWARD coins for testing
public fun create_test_reward(ctx: &mut TxContext): (TreasuryCap<REWARD>, MetadataCap<REWARD>) {
    let (builder, treasury_cap) = coin_registry::new_currency_with_otw<REWARD>(
        REWARD {},
        9,
        b"REWARD".to_string(),
        b"Reward Token".to_string(),
        b"Test reward token for protocol".to_string(),
        b"".to_string(),
        ctx,
    );

    let metadata_cap = builder.finalize(ctx);
    (treasury_cap, metadata_cap)
}

// === Utilities ===

/// Mint additional test coins
public fun mint<T>(cap: &mut TreasuryCap<T>, amount: u64, ctx: &mut TxContext): Coin<T> {
    coin::mint(cap, amount, ctx)
}

/// Burn test coins
public fun burn<T>(cap: &mut TreasuryCap<T>, coin: Coin<T>): u64 {
    coin::burn(cap, coin)
}

/// Get total supply of test coin
public fun total_supply<T>(cap: &TreasuryCap<T>): u64 {
    coin::total_supply(cap)
}
