#[allow(unused_const)]
module enclave::enclave;

use std::bcs;
use sui::ed25519;
use sui::nitro_attestation::NitroAttestationDocument;

use fun to_pcrs as NitroAttestationDocument.to_pcrs;

// === Constants ===
const INITIAL_VERSION: u64 = 1;

// === Errors ===
const EInvalidPCRs: u64 = 0000;
const EInvalidSignature: u64 = 0001;
const EUnauthorized: u64 = 0002;

/// PCR hash type representing the measurements of a TEE enclave
/// * `vector<u8>`: Enclave image file (PCR0)
/// * `vector<u8>`: Enclave kernel (PCR1)
/// * `vector<u8>`: Enclave application (PCR2)
public struct Pcrs(vector<u8>, vector<u8>, vector<u8>) has copy, drop, store;

/// Enclave configuration with public key and PCR measurements
/// * `id`: The unique identifier of the enclave configuration.
/// * `pubkey`: The public key of the enclave for signature verification.
/// * `pcrs`: The PCR measurements of the enclave.
/// * `version`: The version of the enclave configuration.
public struct EnclaveConfig has key, store {
    id: UID,
    pubkey: vector<u8>,
    pcrs: Pcrs,
    version: u64,
}

/// Enclave struct representing a trusted execution environment
/// * `id`: The unique identifier of the enclave.
/// * `pubkey`: The public key of the enclave for signature verification.
/// * `config`: The configuration of the enclave including PCRs and version.
/// * `operator`: The address of the operator who owns the enclave.
public struct Enclave has key, store {
    id: UID,
    pubkey: vector<u8>,
    config: EnclaveConfig,
    operator: address,
}

public struct EnclaveCap<phantom T> has key, store {
    id: UID,
    enclave_id: ID,
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
        id: object::new(ctx),
        pubkey,
        pcrs: Pcrs(pcr0, pcr1, pcr2),
        version: INITIAL_VERSION,
    };
    Enclave {
        id: object::new(ctx),
        pubkey,
        config,
        operator: ctx.sender(),
    }
}

/// Mint an enclave capability, using witness pattern
/// * `enclave`: The enclave to create the capability for.
/// * `ctx`: Transaction context.
public fun mint_cap<T: drop>(enclave: &Enclave, _: T, ctx: &mut TxContext): EnclaveCap<T> {
    assert!(enclave.operator == ctx.sender(), EInvalidSignature);

    EnclaveCap<T> {
        id: object::new(ctx),
        enclave_id: object::id(enclave),
    }
}

/// Update PCRs in the config (package access)
/// * `config`: EnclaveConfig to update
/// * `pcr0`: New PCR0 value
/// * `pcr1`: New PCR1 value
/// * `pcr2`: New PCR2 value
public fun update_pcrs<T: drop>(
    config: &mut EnclaveConfig,
    cap: &EnclaveCap<T>,
    pcr0: vector<u8>,
    pcr1: vector<u8>,
    pcr2: vector<u8>,
) {
    assert!(object::id(config) == cap.enclave_id, EUnauthorized);

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

public fun cap_enclave_id<T>(cap: &EnclaveCap<T>): ID {
    cap.enclave_id
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
