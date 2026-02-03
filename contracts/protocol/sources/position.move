module protocol::position;

use std::string::{Self, utf8, String};
use std::u128;
use sui::display;
use sui::linked_table::{Self, LinkedTable};
use sui::package::{Self, Publisher};

// === Consts ===
const NAME: vector<u8> = b"name";
const LINK: vector<u8> = b"link";
const IMAGE_URL: vector<u8> = b"image_url";
const DESCRIPTION: vector<u8> = b"description";
const PROJECT_URL: vector<u8> = b"project_url";
const CREATOR: vector<u8> = b"creator";
const DEFAULT_DESCRIPTION: vector<u8> = b"Protocol Sponsored Position";
const DEFAULT_LINK: vector<u8> = b"https://bachhd.xyz/position?id={id}";
const DEFAULT_PROJECT_URL: vector<u8> = b"https://bachhd.xyz";
const DEFAULT_CREATOR: vector<u8> = b"Wyner";

// === Errors ===
/// Caller is not authorized to perform the action.
const ENotAuthorized: u64 = 1301;
/// Version mismatch error (when upgrading).
const EVersionMismatch: u64 = 1302;
/// Deposit amount is too small
const EDepositTooSmall: u64 = 1401;
/// Exceed maximum cap
const EExceedMaxCap: u64 = 1402;
/// Position not found
const EPositionNotFound: u64 = 1403;
/// Withdraw shares exceed available shares
const EInsufficientShares: u64 = 1404;
/// Position info is empty
const EPositionInfoEmpty: u64 = 1405;
/// Gas debt exceed limit
const EGasDebtExceedLimit: u64 = 1501;

public struct POSITION has drop {}

public struct PositionManager has store {
    positions: LinkedTable<ID, PositionInfo>,
    last_position_index: u64,
}

/// The Position struct represents a liquidity position in a sponsor pool.
/// * `id`: The unique identifier of the position.
/// * `pool_id`: The identifier of the sponsor pool the position belongs to.
/// * `liquidity`: The amount of liquidity provided in the position.
public struct Position has key, store {
    id: UID,
    pool_id: ID,
    name: String,
    description: String,
    image_url: String,
    shares: u128,
}

/// The PositionInfo struct holds information about a position.
/// * `position_id`: The unique identifier of the position.
/// * `shares`: The number of shares held in the position.
/// * `reward_debt_base_asset_amount`: The reward debt in base asset amount (each pool will have its own base asset likes usdc).
/// * `fee_growth_inside`: The fee growth inside the position.
public struct PositionInfo has copy, drop, store {
    position_id: ID,
    shares: u128,
    reward_debt_base_asset_amount: u128,
    gas_debt_amount: u128,
}

fun init(otw: POSITION, ctx: &mut TxContext) {
    let publisher = package::claim(otw, ctx);

    update_display_internal(
        &publisher,
        utf8(DEFAULT_DESCRIPTION),
        utf8(DEFAULT_LINK),
        utf8(DEFAULT_PROJECT_URL),
        utf8(DEFAULT_CREATOR),
        ctx,
    );
    transfer::public_transfer(publisher, ctx.sender());
}

#[allow(lint(self_transfer))]
fun update_display_internal(
    publisher: &Publisher,
    description: String,
    link: String,
    project_url: String,
    creator: String,
    ctx: &mut TxContext,
) {
    let keys = vector[
        utf8(NAME),
        utf8(LINK),
        utf8(IMAGE_URL),
        utf8(DESCRIPTION),
        utf8(PROJECT_URL),
        utf8(CREATOR),
    ];
    let values = vector[
        utf8(b"{name}"),
        link,
        utf8(b"{image_url}"),
        description,
        project_url,
        creator,
    ];
    let mut display = display::new_with_fields<Position>(
        publisher,
        keys,
        values,
        ctx,
    );
    display::update_version(&mut display);
    transfer::public_transfer(display, ctx.sender());
}

public(package) fun new(ctx: &mut TxContext): PositionManager {
    PositionManager {
        positions: linked_table::new<ID, PositionInfo>(ctx),
        last_position_index: 0,
    }
}

public fun pool_id(position: &Position): ID {
    position.pool_id
}

/// Opens a new position in the sponsor pool.
/// * `manager`: The PositionManager that manages the positions.
/// * `pool_id`: The identifier of the sponsor pool.
/// * `shares`: The number of shares to allocate to the new position.
/// * `ctx`: The transaction context.
/// * Returns the newly created Position.
public(package) fun open_position(
    manager: &mut PositionManager,
    pool_id: ID,
    pool_index: u64,
    url: String,
    ctx: &mut TxContext,
): Position {
    let position_index = manager.last_position_index + 1;
    let position = Position {
        id: object::new(ctx),
        pool_id,
        name: new_position_name(pool_index, position_index),
        description: string::utf8(DEFAULT_DESCRIPTION),
        image_url: url,
        shares: 0,
    };

    let position_id = object::id(&position);

    let position_info = PositionInfo {
        position_id,
        shares: 0,
        reward_debt_base_asset_amount: 0,
        gas_debt_amount: 0,
    };

    manager.positions.push_back(position_id, position_info);
    manager.last_position_index = position_index;

    position
}

/// Closes an existing position in the sponsor pool.
/// * `manager`: The PositionManager that manages the positions.
/// * `position`: The Position to be closed.
public(package) fun close_position(manager: &mut PositionManager, position: Position) {
    let position_id = object::id(&position);

    manager.positions.remove(position_id);
    destroy(position);
}

public(package) fun increment_shares(
    position: &mut Position,
    manager: &mut PositionManager,
    shares: u128,
    current_acc_reward_per_share: u128,
    current_acc_gas_per_share: u128,
) {
    let position_id = object::id(position);
    let position_info = borrow_mut_position_info(manager, position_id);

    update_reward_debt_base_asset_amount_internal(
        position_info,
        shares,
        current_acc_reward_per_share,
        current_acc_gas_per_share,
        true,
    );

    position_info.shares = position_info.shares + shares;
    position.shares = position.shares + shares;
}

public(package) fun decrement_shares(
    position: &mut Position,
    manager: &mut PositionManager,
    shares: u128,
    current_acc_reward_per_share: u128,
    current_acc_gas_per_share: u128,
) {
    let position_id = object::id(position);
    let position_info = borrow_mut_position_info(manager, position_id);

    assert!(position_info.shares >= shares, EInsufficientShares);

    update_reward_debt_base_asset_amount_internal(
        position_info,
        shares,
        current_acc_reward_per_share,
        current_acc_gas_per_share,
        false,
    );

    position_info.shares = position_info.shares - shares;
    position.shares = position.shares - shares;
}

public(package) fun harvest(
    position: &Position,
    manager: &mut PositionManager,
    current_acc_reward_per_share: u128,
    current_acc_gas_per_share: u128,
): (u128, u128) {
    let position_id = object::id(position);
    let info = borrow_mut_position_info(manager, position_id);

    let accumulated_reward = info.shares * current_acc_reward_per_share;
    let reward_debt = info.reward_debt_base_asset_amount;
    let pending_reward = if (accumulated_reward > reward_debt) {
        accumulated_reward - reward_debt
    } else { 0 };

    let accumulated_gas = info.shares * current_acc_gas_per_share;
    let gas_debt = info.gas_debt_amount;
    let pending_gas = if (accumulated_gas > gas_debt) {
        accumulated_gas - gas_debt
    } else { 0 };

    info.reward_debt_base_asset_amount = accumulated_reward;
    info.gas_debt_amount = accumulated_gas;

    (pending_reward, pending_gas)
}

public(package) fun update_and_reset_reward_debt_base_asset(
    manager: &mut PositionManager,
    position_id: ID,
    new_reward_debt_base_asset_amount: u128,
    new_gas_debt_amount: u128,
): u128 {
    let position_info = borrow_mut_position_info(manager, position_id);
    let debt = position_info.reward_debt_base_asset_amount;
    position_info.reward_debt_base_asset_amount = new_reward_debt_base_asset_amount;
    position_info.gas_debt_amount = new_gas_debt_amount;

    debt
}

public(package) fun reset_reward_debt_base_asset(
    manager: &mut PositionManager,
    position_id: ID,
): u128 {
    let position_info = borrow_mut_position_info(manager, position_id);
    let debt = position_info.reward_debt_base_asset_amount;
    position_info.reward_debt_base_asset_amount = 0;
    position_info.gas_debt_amount = 0;

    debt
}

public(package) fun update_and_reset_gas_debt(
    manager: &mut PositionManager,
    position_id: ID,
    new_gas_debt_amount: u128,
): u128 {
    let position_info = borrow_mut_position_info(manager, position_id);
    let debt = position_info.gas_debt_amount;
    position_info.gas_debt_amount = new_gas_debt_amount;

    debt
}

public(package) fun reset_gas_debt(manager: &mut PositionManager, position_id: ID): u128 {
    let position_info = borrow_mut_position_info(manager, position_id);
    let debt = position_info.gas_debt_amount;
    position_info.gas_debt_amount = 0;

    debt
}

public fun fetch_positions(
    manager: &PositionManager,
    start: vector<ID>,
    limit: u64,
): vector<PositionInfo> {
    if (limit == 0) {
        return vector::empty<PositionInfo>()
    };

    let mut results = vector::empty<PositionInfo>();
    let mut next_position_id = if (start.is_empty()) {
        *manager.positions.front()
    } else {
        let pos_id = *start.borrow(0);
        assert!(manager.positions.contains(pos_id), EPositionNotFound);
        option::some(pos_id)
    };

    let mut count = 0;
    while (option::is_some(&next_position_id) && count < limit) {
        let pos_id = option::extract(&mut next_position_id);
        let pos_info = *manager.positions.borrow(pos_id);
        results.push_back(pos_info);
        next_position_id = *manager.positions.next(pos_id);
        count = count + 1;
    };

    results
}

public fun shares(position: &Position): u128 {
    position.shares
}

public fun name(position: &Position): &String {
    &position.name
}

public fun description(position: &Position): &String {
    &position.description
}

public fun image_url(position: &Position): &String {
    &position.image_url
}

fun borrow_mut_position_info(manager: &mut PositionManager, position_id: ID): &mut PositionInfo {
    assert!(manager.positions.contains(position_id), EPositionNotFound);
    let position_info = manager.positions.borrow_mut(position_id);
    assert!(position_info.position_id == position_id, EPositionNotFound);

    position_info
}

fun remove_position_info_for_restore(manager: &mut PositionManager, position_id: ID) {
    assert!(manager.positions.contains(position_id), EPositionNotFound);
    manager.positions.remove(position_id);
}

fun new_position_name(pool_index: u64, position_index: u64): String {
    let mut name = string::utf8(b"Position | Sponsor Pool");
    name.append(string::utf8(b" "));
    name.append(pool_index.to_string());
    name.append_utf8(b"-");
    name.append(position_index.to_string());
    name
}

fun update_reward_debt_base_asset_amount_internal(
    position_info: &mut PositionInfo,
    shares: u128,
    current_acc_reward_per_share: u128,
    current_gas_per_share: u128,
    is_increment: bool,
) {
    let reward_amount = shares * current_acc_reward_per_share;
    let gas_amount = shares * current_gas_per_share;

    if (is_increment) {
        position_info.reward_debt_base_asset_amount =
            position_info.reward_debt_base_asset_amount + reward_amount;
        position_info.gas_debt_amount = position_info.gas_debt_amount + gas_amount;
    } else {
        position_info.reward_debt_base_asset_amount =
            position_info.reward_debt_base_asset_amount - reward_amount;
        position_info.gas_debt_amount = position_info.gas_debt_amount - gas_amount;
    }
}

fun destroy(position: Position) {
    let Position {
        id,
        pool_id: _,
        shares: _,
        name: _,
        description: _,
        image_url: _,
    } = position;

    object::delete(id);
}
