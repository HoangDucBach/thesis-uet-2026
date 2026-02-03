module protocol::constants;

const ACC_PRECISION: u128 = 1_000_000_000_000;
const BPS: u128 = 10_000;

public(package) fun acc_precision(): u128 {
    ACC_PRECISION
}

public(package) fun bps(): u128 {
    BPS
}
