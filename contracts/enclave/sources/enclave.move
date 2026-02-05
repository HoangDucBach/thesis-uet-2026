#[allow(unused_const)]
module enclave::enclave;

use std::bcs;
use std::string::String;
use sui::ed25519;
use sui::nitro_attestation::NitroAttestationDocument;

use fun to_pcrs as NitroAttestationDocument.to_pcrs;

// === Constants ===
const INITIAL_VERSION: u64 = 0;

// === Errors ===
const EInvalidPCRs: u64 = 0000;
const EInvalidConfigVersion: u64 = 0001;
const EInvalidCap: u64 = 0002;
const EInvalidOwner: u64 = 0003;

/// PCR hash type representing the measurements of a TEE enclave
/// * `vector<u8>`: Enclave image file (PCR0)
/// * `vector<u8>`: Enclave kernel (PCR1)
/// * `vector<u8>`: Enclave application (PCR2)
public struct Pcrs(vector<u8>, vector<u8>, vector<u8>) has copy, drop, store;

/// The expected PCRs - Shared Object (Single Source of Truth)
/// * `id`: The unique identifier of the enclave configuration.
/// * `name`: A human-readable name for the enclave configuration.
/// * `pcrs`: The PCR measurements of the enclave.
/// * `capability_id`: The ID of the capability that can update this config.
/// * `version`: The version of the enclave configuration (incremented when PCRs change).
public struct EnclaveConfig<phantom T> has key {
    id: UID,
    name: String,
    pcrs: Pcrs,
    capability_id: ID,
    version: u64,
}

/// A verified enclave instance, with its public key
/// * `id`: The unique identifier of the enclave.
/// * `pubkey`: The public key of the enclave for signature verification.
/// * `config_version`: Points to the EnclaveConfig's version.
/// * `owner`: The address of the operator who owns the enclave.
public struct Enclave<phantom T> has key {
    id: UID,
    pubkey: vector<u8>,
    config_version: u64,
    owner: address,
}

/// A apcability to update the enclave config
/// * `id`: The unique identifier of the capability.
public struct EnclaveCap<phantom T> has key, store {
    id: UID,
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

/// Create a new `Cap` using a `witness` T from a module.
/// * `_`: The witness token proving ownership of type T.
/// * `ctx`: Transaction context.
public fun new_cap<T: drop>(_: T, ctx: &mut TxContext): EnclaveCap<T> {
    EnclaveCap {
        id: object::new(ctx),
    }
}

/// Create enclave config.
/// * `cap`: The capability required to create this config.
/// * `name`: A human-readable name for the enclave configuration.
/// * `pcr0`: The expected PCR0 value for the enclave.
/// * `pcr1`: The expected PCR1 value for the enclave.
/// * `pcr2`: The expected PCR2 value for the enclave.
/// * `ctx`: Transaction context.
public fun create_enclave_config<T: drop>(
    cap: &EnclaveCap<T>,
    name: String,
    pcr0: vector<u8>,
    pcr1: vector<u8>,
    pcr2: vector<u8>,
    ctx: &mut TxContext,
) {
    let enclave_config = EnclaveConfig<T> {
        id: object::new(ctx),
        name,
        pcrs: Pcrs(pcr0, pcr1, pcr2),
        capability_id: cap.id.to_inner(),
        version: INITIAL_VERSION,
    };

    transfer::share_object(enclave_config);
}

/// Register enclave with attestation document.
/// * `enclave_config`: The enclave configuration to register against.
/// * `document`: The Nitro attestation document containing PCRs and public key.
/// * `ctx`: Transaction context.
public fun register_enclave<T>(
    enclave_config: &EnclaveConfig<T>,
    document: NitroAttestationDocument,
    ctx: &mut TxContext,
) {
    let pubkey = enclave_config.load_pk(&document);

    let enclave = Enclave<T> {
        id: object::new(ctx),
        pubkey,
        config_version: enclave_config.version,
        owner: ctx.sender(),
    };

    transfer::share_object(enclave);
}

/// Verify signature using enclave.
/// * `enclave`: The enclave to verify signature for.
/// * `intent_scope`: Type of operation being verified.
/// * `timestamp_ms`: Timestamp of the message.
/// * `payload`: The actual payload data.
/// * `signature`: Ed25519 signature to verify.
public fun verify_signature<T, P: drop>(
    enclave: &Enclave<T>,
    intent_scope: u8,
    timestamp_ms: u64,
    payload: P,
    signature: &vector<u8>,
): bool {
    let intent_message = create_intent_message(intent_scope, timestamp_ms, payload);
    let payload_bytes = bcs::to_bytes(&intent_message);
    ed25519::ed25519_verify(signature, &enclave.pubkey, &payload_bytes)
}

/// Update PCRs in the config (requires capability).
/// * `config`: EnclaveConfig to update.
/// * `cap`: The capability required to perform this operation.
/// * `pcr0`: New PCR0 value.
/// * `pcr1`: New PCR1 value.
/// * `pcr2`: New PCR2 value.
public fun update_pcrs<T: drop>(
    config: &mut EnclaveConfig<T>,
    cap: &EnclaveCap<T>,
    pcr0: vector<u8>,
    pcr1: vector<u8>,
    pcr2: vector<u8>,
) {
    cap.assert_is_valid_for_config(config);
    config.pcrs = Pcrs(pcr0, pcr1, pcr2);
    config.version = config.version + 1;
}

/// Update config name (requires capability).
/// * `config`: EnclaveConfig to update.
/// * `cap`: The capability required to perform this operation.
/// * `name`: New name for the enclave configuration.
public fun update_name<T: drop>(config: &mut EnclaveConfig<T>, cap: &EnclaveCap<T>, name: String) {
    cap.assert_is_valid_for_config(config);
    config.name = name;
}

/// Getters
public fun pcr0<T>(config: &EnclaveConfig<T>): &vector<u8> {
    &config.pcrs.0
}

public fun pcr1<T>(config: &EnclaveConfig<T>): &vector<u8> {
    &config.pcrs.1
}

public fun pcr2<T>(config: &EnclaveConfig<T>): &vector<u8> {
    &config.pcrs.2
}

public fun pubkey<T>(enclave: &Enclave<T>): &vector<u8> {
    &enclave.pubkey
}

/// Destroy old enclave when config version updated.
/// * `e`: The old enclave to destroy.
/// * `config`: The current enclave configuration.
public fun destroy_old_enclave<T>(e: Enclave<T>, config: &EnclaveConfig<T>) {
    assert!(e.config_version < config.version, EInvalidConfigVersion);
    let Enclave { id, .. } = e;
    id.delete();
}

/// Owner can destroy their own enclave.
/// * `e`: The enclave to destroy.
/// * `ctx`: Transaction context.
public fun destroy_enclave_by_owner<T>(e: Enclave<T>, ctx: &mut TxContext) {
    assert!(e.owner == ctx.sender(), EInvalidOwner);
    let Enclave { id, .. } = e;
    id.delete();
}

/// Helper functions
fun assert_is_valid_for_config<T>(cap: &EnclaveCap<T>, enclave_config: &EnclaveConfig<T>) {
    assert!(cap.id.to_inner() == enclave_config.capability_id, EInvalidCap);
}

fun load_pk<T>(enclave_config: &EnclaveConfig<T>, document: &NitroAttestationDocument): vector<u8> {
    assert!(document.to_pcrs() == enclave_config.pcrs, EInvalidPCRs);
    (*document.public_key()).destroy_some()
}

public fun to_pcrs(document: &NitroAttestationDocument): Pcrs {
    let pcrs = document.pcrs();
    Pcrs(*pcrs[0].value(), *pcrs[1].value(), *pcrs[2].value())
}

/// Create an intent message (helper for signing).
/// * `intent`: u8 - Type of operation (liquidation, update, etc).
/// * `timestamp_ms`: u64 - Timestamp in milliseconds (replay protection).
/// * `payload`: T - Actual operation data.
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
