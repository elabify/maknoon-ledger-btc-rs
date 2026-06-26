use std::str::FromStr;
use std::sync::Arc;

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use bitcoin::bip32::DerivationPath;
use bitcoin::Psbt;
use ledger_bitcoin_client::async_client::BitcoinClient as UpstreamClient;
use ledger_bitcoin_client::wallet::Version as UpstreamVersion;
use ledger_bitcoin_client::{
    PartialSignature, SignPsbtYieldedObject, WalletPolicy as UpstreamPolicy, WalletPubKey,
};

use crate::adapter::{map_bitcoin_client_error, ForeignTransportAdapter};
use crate::error::LedgerError;
use crate::transport::Transport;
use crate::types::{RegisteredPolicy, WalletPolicy};

/// Top-level client for talking to the Ledger Bitcoin app over an
/// injected transport. Construct once per session, then call any
/// number of `get_master_fingerprint` / `get_extended_pubkey` /
/// `sign_psbt` / `register_wallet` / `get_wallet_address` methods.
///
/// Thread-safe: methods take `&self` and the underlying upstream
/// client serializes its own state. Concurrent calls naturally
/// queue on the foreign transport (BLE allows only one in-flight
/// APDU exchange).
#[derive(uniffi::Object)]
pub struct LedgerBitcoinClient {
    client: UpstreamClient<ForeignTransportAdapter>,
}

#[uniffi::export(async_runtime = "tokio")]
impl LedgerBitcoinClient {
    /// Construct a new client backed by the given transport.
    /// Transport ownership is shared via `Arc`. Typical lifecycle
    /// is one client per device session.
    #[uniffi::constructor]
    pub fn new(transport: Arc<dyn Transport>) -> Arc<Self> {
        let adapter = ForeignTransportAdapter::new(transport);
        let client = UpstreamClient::new(adapter);
        Arc::new(Self { client })
    }

    /// Returns the 4-byte master pubkey fingerprint of the seed
    /// loaded on the device. Display back to the user as
    /// lowercase hex (e.g. `f5acc2fd`).
    pub async fn get_master_fingerprint(&self) -> Result<Vec<u8>, LedgerError> {
        let fp = self
            .client
            .get_master_fingerprint()
            .await
            .map_err(map_bitcoin_client_error)?;
        Ok(fp.to_bytes().to_vec())
    }

    /// Returns the base58-encoded BIP-32 extended public key at
    /// the given derivation path. `display = true` prompts the
    /// user on-device to confirm before returning.
    ///
    /// Path syntax follows BIP-32 with `'` for hardened, e.g.
    /// `"m/84'/0'/0'"` for BIP-84 mainnet account 0.
    pub async fn get_extended_pubkey(
        &self,
        path: String,
        display: bool,
    ) -> Result<String, LedgerError> {
        let path = DerivationPath::from_str(&path).map_err(|e| LedgerError::Protocol {
            reason: format!("invalid derivation path '{path}': {e}"),
        })?;
        let xpub = self
            .client
            .get_extended_pubkey(&path, display)
            .await
            .map_err(map_bitcoin_client_error)?;
        Ok(xpub.to_string())
    }

    /// Sign a PSBT against the given wallet policy. Returns the
    /// signed PSBT base64 with `PSBT_IN_PARTIAL_SIG` entries
    /// merged in; feed it to a finalizer (BDK, libwally, Bitcoin
    /// Core) to extract the broadcastable transaction.
    ///
    /// Accepts PSBT v0 (BIP-174) base64 on input. Upstream
    /// handles the v0→v2 conversion for the SIGN_PSBT command.
    pub async fn sign_psbt(
        &self,
        psbt_base64: String,
        policy: WalletPolicy,
    ) -> Result<String, LedgerError> {
        let bytes = B64
            .decode(psbt_base64.trim())
            .map_err(|e| LedgerError::invalid_psbt(format!("base64 decode failed: {e}")))?;
        let mut psbt = Psbt::deserialize(&bytes)
            .map_err(|e| LedgerError::invalid_psbt(format!("PSBT parse failed: {e}")))?;

        let upstream_policy = build_upstream_policy(&policy)?;
        let hmac = hmac_bytes(&policy)?;
        let hmac_ref = hmac.as_ref();

        let yields = self
            .client
            .sign_psbt(&psbt, &upstream_policy, hmac_ref)
            .await
            .map_err(map_bitcoin_client_error)?;

        // Merge each yielded partial signature back into the PSBT.
        // Tapscript and MuSig2 yields are accepted but require the
        // matching script/key structures to already be present in
        // the PSBT; we just record them where they belong.
        for (input_index, obj) in yields {
            let input_count = psbt.inputs.len();
            let input = psbt.inputs.get_mut(input_index).ok_or_else(|| {
                LedgerError::protocol(format!(
                    "device yielded signature for input {input_index} but PSBT has only {input_count} inputs"
                ))
            })?;
            match obj {
                SignPsbtYieldedObject::Partial(PartialSignature::Sig(pubkey, sig)) => {
                    input.partial_sigs.insert(pubkey, sig);
                }
                SignPsbtYieldedObject::Partial(PartialSignature::TapScriptSig(
                    xonly,
                    leaf_hash,
                    sig,
                )) => {
                    if let Some(leaf) = leaf_hash {
                        input.tap_script_sigs.insert((xonly, leaf), sig);
                    } else {
                        // Key-spend (no leaf): goes in tap_key_sig.
                        input.tap_key_sig = Some(sig);
                    }
                }
                SignPsbtYieldedObject::MusigPubNonce(_)
                | SignPsbtYieldedObject::MusigPartialSignature(_) => {
                    // MuSig2 yields are part of a multi-round
                    // signing flow we don't expose in v1. Surface
                    // a clear error so callers know to use the
                    // upstream crate directly if they need it.
                    return Err(LedgerError::protocol(
                        "MuSig2 yields are not yet handled by ledger-btc-core",
                    ));
                }
                SignPsbtYieldedObject::Unknown(bytes) => {
                    return Err(LedgerError::protocol(format!(
                        "unknown YIELD payload ({} bytes); upstream firmware may be newer than client",
                        bytes.len()
                    )));
                }
                // SignPsbtYieldedObject is #[non_exhaustive]; this
                // arm catches future variants from upstream so we
                // surface a clean error rather than silently
                // ignoring a signature.
                _ => {
                    return Err(LedgerError::protocol(
                        "device yielded an object variant unknown to this client",
                    ));
                }
            }
        }

        let signed_bytes = psbt.serialize();
        Ok(B64.encode(signed_bytes))
    }

    /// Sign an arbitrary message with the key at `path` (a full BIP32 path)
    /// in the standard "Bitcoin Signed Message" format. The Ledger app shows
    /// the message + address and sets the address-type header byte from the
    /// path's purpose. Returns the recovered address + base64 signature,
    /// matching the software + Trezor message-sign paths.
    pub async fn sign_message(
        &self,
        path: String,
        message: Vec<u8>,
        network: crate::message::BtcMsgNetwork,
    ) -> Result<crate::message::BtcSignedMessage, LedgerError> {
        let dpath = DerivationPath::from_str(&path)
            .map_err(|e| LedgerError::protocol(format!("invalid derivation path '{path}': {e}")))?;
        let (header, sig) = self
            .client
            .sign_message(&message, &dpath)
            .await
            .map_err(map_bitcoin_client_error)?;
        let mut packed = Vec::with_capacity(65);
        packed.push(header);
        packed.extend_from_slice(&sig.serialize_compact());
        let signature = B64.encode(&packed);
        let script_type = crate::message::script_type_from_path(&path);
        let address = crate::message::recover_address(&message, &packed, script_type, network)
            .ok_or_else(|| LedgerError::protocol("could not recover signing address"))?;
        Ok(crate::message::BtcSignedMessage { address, signature })
    }

    /// Register a custom wallet policy on the device. The user
    /// confirms once on-device; the returned `RegisteredPolicy.hmac`
    /// is the trust anchor for future `sign_psbt` and
    /// `get_wallet_address` calls.
    ///
    /// Default policies (empty name, canonical BIP-84/86 templates)
    /// don't need registration; pass `hmac = None` directly.
    pub async fn register_wallet(
        &self,
        policy: WalletPolicy,
    ) -> Result<RegisteredPolicy, LedgerError> {
        let upstream_policy = build_upstream_policy(&policy)?;
        let (id, hmac) = self
            .client
            .register_wallet(&upstream_policy)
            .await
            .map_err(map_bitcoin_client_error)?;
        Ok(RegisteredPolicy {
            id: id.to_vec(),
            hmac: hmac.to_vec(),
        })
    }

    /// Returns the address at `<change>/<index>` for the given
    /// wallet policy. `display = true` prompts on-device for the
    /// user to confirm visually before the address is returned.
    /// Use this on first receive flows so the user can verify the
    /// device-computed address matches what the host shows.
    pub async fn get_wallet_address(
        &self,
        policy: WalletPolicy,
        change: u32,
        index: u32,
        display: bool,
    ) -> Result<String, LedgerError> {
        let upstream_policy = build_upstream_policy(&policy)?;
        let hmac = hmac_bytes(&policy)?;
        let hmac_ref = hmac.as_ref();
        // Upstream takes `change: bool` (not arbitrary u32) — the
        // chain index in BIP-84 derivations is exactly 0 (receive)
        // or 1 (change). Map non-zero to change for compatibility,
        // but validate strictly to catch caller bugs early.
        let change_bool = match change {
            0 => false,
            1 => true,
            other => {
                return Err(LedgerError::InvalidPolicy {
                    reason: format!("change must be 0 or 1, got {other}"),
                })
            }
        };
        let address = self
            .client
            .get_wallet_address(&upstream_policy, hmac_ref, change_bool, index, display)
            .await
            .map_err(map_bitcoin_client_error)?;
        // The upstream call returns an unchecked Address. Assuming
        // checked is safe at the wire boundary because the device
        // is the trust anchor on what address it just computed.
        Ok(address.assume_checked().to_string())
    }
}

/// Translate our UniFFI `WalletPolicy` record into upstream's
/// `WalletPolicy` value. Key origin strings are parsed via
/// `WalletPubKey::from_str`; we wrap parse errors into
/// `LedgerError::InvalidPolicy` with the offending string in the
/// message for easy debugging.
fn build_upstream_policy(p: &WalletPolicy) -> Result<UpstreamPolicy, LedgerError> {
    let mut parsed_keys: Vec<WalletPubKey> = Vec::with_capacity(p.keys.len());
    for k in &p.keys {
        let pk = WalletPubKey::from_str(k).map_err(|e| LedgerError::InvalidPolicy {
            reason: format!("key '{k}' did not parse as a wallet pubkey: {e:?}"),
        })?;
        parsed_keys.push(pk);
    }
    // All policies we generate target Bitcoin app v2.x firmware
    // (the only one that implements SIGN_PSBT v2). V1 was the old
    // app and isn't reachable through this client.
    Ok(UpstreamPolicy::new(
        p.name.clone(),
        UpstreamVersion::V2,
        p.descriptor_template.clone(),
        parsed_keys,
    ))
}

/// Convert the optional 32-byte HMAC from our UniFFI record into
/// the `[u8; 32]` upstream expects. Validates length; passes
/// `None` through unchanged.
fn hmac_bytes(p: &WalletPolicy) -> Result<Option<[u8; 32]>, LedgerError> {
    let Some(ref h) = p.hmac else {
        return Ok(None);
    };
    if h.len() != 32 {
        return Err(LedgerError::InvalidPolicy {
            reason: format!("wallet HMAC must be 32 bytes, got {}", h.len()),
        });
    }
    let mut out = [0u8; 32];
    out.copy_from_slice(h);
    Ok(Some(out))
}
