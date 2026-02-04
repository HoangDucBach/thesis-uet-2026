#[allow(unused_const)]
module enclave::enclave;

use std::bcs;
use sui::ed25519;
use sui::nitro_attestation::NitroAttestationDocument;

use fun to_pcrs as NitroAttestationDocument.to_pcrs;

// === Constants ===
const INITIAL_VERSION: u64 = 1;

// === Errors ===
const EInvalidPCRs: u64 = 0;
const EInvalidSignature: u64 = 1;

/// PCR hash type representing the measurements of a TEE enclave
/// * `vector<u8>`: Enclave image file (PCR0)
/// * `vector<u8>`: Enclave kernel (PCR1)
/// * `vector<u8>`: Enclave application (PCR2)
public struct Pcrs(vector<u8>, vector<u8>, vector<u8>) has copy, drop, store;

/// Enclave configuration with public key and PCR measurements
public struct EnclaveConfig has copy, drop, store {
    pubkey: vector<u8>,
    pcrs: Pcrs,
    version: u64,
}

public struct Enclave has copy, drop, store {
    pubkey: vector<u8>,
    config: EnclaveConfig,
    operator: address,
}

/// Intent message for signing and verification
/// * `intent`: u8 - Type of operation (liquidation, update, etc)
/// * `timestamp_ms`: u64 - Timestamp in milliseconds (replay protection)
/// * `payload`: T - Actual operation data
public struct IntentMessage<T: drop> has copy, drop {
    intent: u8,
    timestamp_ms: u64,
    payload: T,
}

/// Create a new enclave config with PCRs
public fun new(
    pubkey: vector<u8>,
    pcr0: vector<u8>,
    pcr1: vector<u8>,
    pcr2: vector<u8>,
    ctx: &mut TxContext,
): Enclave {
    let config = EnclaveConfig {
        pubkey,
        pcrs: Pcrs(pcr0, pcr1, pcr2),
        version: INITIAL_VERSION,
    };
    Enclave {
        pubkey,
        config,
        operator: ctx.sender(),
    }
}

/// Update PCRs in the config
/// * `config`: EnclaveConfig to update
/// * `pcr0`: New PCR0 value
/// * `pcr1`: New PCR1 value
/// * `pcr2`: New PCR2 value
public(package) fun update_pcrs(
    config: &mut EnclaveConfig,
    pcr0: vector<u8>,
    pcr1: vector<u8>,
    pcr2: vector<u8>,
) {
    config.pcrs = Pcrs(pcr0, pcr1, pcr2);
    config.version = config.version + 1;
}

/// Upgrade version
public(package) fun upgrade_version(config: &mut EnclaveConfig) {
    config.version = config.version + 1;
}

/// Create an intent message (helper for signing)
public fun create_intent_message<P: drop>(
    intent: u8,
    timestamp_ms: u64,
    payload: P,
): IntentMessage<P> {
    IntentMessage {
        intent,
        timestamp_ms,
        payload,
    }
}

public fun pubkey(enclave: &Enclave): vector<u8> {
    enclave.pubkey
}

/// Update enclave public key (missing function for keeper registration)
public fun update_pubkey(enclave: &mut Enclave, new_pubkey: vector<u8>) {
    enclave.pubkey = new_pubkey;
    enclave.config.pubkey = new_pubkey;
}

/// Verify signature using enclave directly
/// * `enclave`: Enclave containing config and pubkey
/// * `intent_scope`: Type of operation being verified
/// * `timestamp_ms`: Timestamp of the message
/// * `payload`: The actual payload data
/// * `signature`: Ed25519 signature to verify
public fun verify_signature<P: drop>(
    enclave: &Enclave,
    intent_scope: u8,
    timestamp_ms: u64,
    payload: P,
    signature: &vector<u8>,
): bool {
    verify_signature_internal(&enclave.config, intent_scope, timestamp_ms, payload, signature)
}

public fun pcr0(enclave: &Enclave): vector<u8> {
    enclave.config.pcrs.0
}

public fun pcr1(enclave: &Enclave): vector<u8> {
    enclave.config.pcrs.1
}

public fun pcr2(enclave: &Enclave): vector<u8> {
    enclave.config.pcrs.2
}

public fun version(enclave: &Enclave): u64 {
    enclave.config.version
}

public fun load_pk(config: &EnclaveConfig, document: &NitroAttestationDocument): vector<u8> {
    assert!(document.to_pcrs() == config.pcrs, EInvalidPCRs);
    (*document.public_key()).destroy_some()
}

public fun to_pcrs(document: &NitroAttestationDocument): Pcrs {
    let pcrs = document.pcrs();
    Pcrs(*pcrs[0].value(), *pcrs[1].value(), *pcrs[2].value())
}

/// Verify signature using enclave config internally
fun verify_signature_internal<P: drop>(
    config: &EnclaveConfig,
    intent_scope: u8,
    timestamp_ms: u64,
    payload: P,
    signature: &vector<u8>,
): bool {
    let intent_message = create_intent_message(intent_scope, timestamp_ms, payload);
    let payload_bytes = bcs::to_bytes(&intent_message);
    ed25519::ed25519_verify(signature, &config.pubkey, &payload_bytes)
}
