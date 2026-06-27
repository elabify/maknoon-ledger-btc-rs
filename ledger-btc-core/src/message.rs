// Software Bitcoin message signing + verification in the legacy/Electrum
// "Bitcoin Signed Message" format (BIP-137), including the segwit
// address-type header bytes that Electrum, Trezor, and Ledger use:
//
//   legacy P2PKH          header 31..34
//   nested segwit (P2SH)  header 35..38
//   native segwit (P2WPKH) header 39..42
//
// (compressed-key + recovery-id encoded in the low bits).
//
// This is keyless software crypto (no Ledger involved); it lives in this
// crate because it already depends on rust-bitcoin. The functions are
// STATELESS: the host app derives the signing key and passes the 32-byte
// secret; rust-bitcoin produces the address (bech32/base58) and the
// recoverable signature so iOS and Android stay byte-identical and
// interoperate with Electrum / Bitcoin Core / hardware wallets.

use base64::Engine;
use bitcoin::hashes::Hash as _;
use bitcoin::secp256k1::ecdsa::{RecoverableSignature, RecoveryId};
use bitcoin::secp256k1::{Message, Secp256k1, SecretKey};
use bitcoin::sign_message::signed_msg_hash;
use bitcoin::{Address, CompressedPublicKey, KnownHrp, Network, PublicKey};

/// Address type (BIP44 / BIP49 / BIP84 purpose) the signature binds to.
#[derive(uniffi::Enum, Clone, Copy)]
pub enum BtcMsgScriptType {
    Legacy,
    NestedSegwit,
    NativeSegwit,
}

/// Network the bound address is rendered for.
#[derive(uniffi::Enum, Clone, Copy)]
pub enum BtcMsgNetwork {
    Mainnet,
    Testnet,
    Signet,
}

#[derive(uniffi::Record)]
pub struct BtcSignedMessage {
    /// The legacy/segwit address (per script type + network) the signature
    /// is bound to; this is what a verifier checks against.
    pub address: String,
    /// Base64 "Bitcoin Signed Message" signature (65 bytes: header || r || s).
    pub signature: String,
}

#[derive(uniffi::Error, Debug, thiserror::Error)]
pub enum BtcMsgError {
    #[error("invalid private key")]
    InvalidKey,
    #[error("could not build address")]
    AddressError,
}

fn network(n: BtcMsgNetwork) -> Network {
    match n {
        BtcMsgNetwork::Mainnet => Network::Bitcoin,
        // Testnet and Signet share the same address encodings/prefixes.
        BtcMsgNetwork::Testnet => Network::Testnet,
        BtcMsgNetwork::Signet => Network::Signet,
    }
}

fn hrp(net: Network) -> KnownHrp {
    match net {
        Network::Bitcoin => KnownHrp::Mainnet,
        Network::Regtest => KnownHrp::Regtest,
        _ => KnownHrp::Testnets,
    }
}

fn address_for(
    secp_pk: &bitcoin::secp256k1::PublicKey,
    ty: BtcMsgScriptType,
    net: Network,
) -> Address {
    let pk = PublicKey::new(*secp_pk);
    let cpk = CompressedPublicKey(*secp_pk);
    match ty {
        BtcMsgScriptType::Legacy => Address::p2pkh(pk, net),
        BtcMsgScriptType::NestedSegwit => Address::p2shwpkh(&cpk, net),
        BtcMsgScriptType::NativeSegwit => Address::p2wpkh(&cpk, hrp(net)),
    }
}

/// Sign `message` with `secret_key` (raw 32 bytes), producing an Electrum
/// "Bitcoin Signed Message" signature bound to the address of `script_type`
/// on `network`.
#[uniffi::export]
pub fn btc_sign_message(
    secret_key: Vec<u8>,
    message: String,
    script_type: BtcMsgScriptType,
    network_kind: BtcMsgNetwork,
) -> Result<BtcSignedMessage, BtcMsgError> {
    let sk = SecretKey::from_slice(&secret_key).map_err(|_| BtcMsgError::InvalidKey)?;
    let secp = Secp256k1::new();
    let secp_pk = sk.public_key(&secp);
    let net = network(network_kind);
    let address = address_for(&secp_pk, script_type, net).to_string();

    let hash = signed_msg_hash(&message);
    let msg = Message::from_digest(hash.to_byte_array());
    let recsig = secp.sign_ecdsa_recoverable(&msg, &sk);
    let (recid, sig64) = recsig.serialize_compact();

    // Header base per address type (compressed key): legacy 31, nested 35,
    // native 39; + recovery id (0..3).
    let base: u8 = match script_type {
        BtcMsgScriptType::Legacy => 31,
        BtcMsgScriptType::NestedSegwit => 35,
        BtcMsgScriptType::NativeSegwit => 39,
    };
    let header = base + (recid.to_i32() as u8);
    let mut out = Vec::with_capacity(65);
    out.push(header);
    out.extend_from_slice(&sig64);

    Ok(BtcSignedMessage {
        address,
        signature: base64::engine::general_purpose::STANDARD.encode(out),
    })
}

/// Verify an Electrum "Bitcoin Signed Message" signature: recover the public
/// key and check whether it produces `address` under any standard address
/// type (legacy / nested / native segwit) on mainnet or testnet/signet.
/// Keyless; accepts a signature + address + message from any source.
#[uniffi::export]
pub fn btc_verify_message(address: String, message: String, signature: String) -> bool {
    let want = address.trim();
    let bytes = match base64::engine::general_purpose::STANDARD.decode(signature.trim()) {
        Ok(b) if b.len() == 65 => b,
        _ => return false,
    };
    let header = bytes[0];
    if header < 27 {
        return false;
    }
    let recid_val = ((header - 27) & 0x03) as i32;
    let recid = match RecoveryId::from_i32(recid_val) {
        Ok(r) => r,
        Err(_) => return false,
    };
    let recsig = match RecoverableSignature::from_compact(&bytes[1..65], recid) {
        Ok(s) => s,
        Err(_) => return false,
    };
    let hash = signed_msg_hash(&message);
    let msg = Message::from_digest(hash.to_byte_array());
    let secp = Secp256k1::verification_only();
    let secp_pk = match secp.recover_ecdsa(&msg, &recsig) {
        Ok(pk) => pk,
        Err(_) => return false,
    };

    // Compare against every standard address type on mainnet + testnet
    // (signet shares testnet encodings), so the header's type bits do not
    // have to be trusted.
    for net in [Network::Bitcoin, Network::Testnet] {
        for ty in [
            BtcMsgScriptType::Legacy,
            BtcMsgScriptType::NestedSegwit,
            BtcMsgScriptType::NativeSegwit,
        ] {
            if address_for(&secp_pk, ty, net).to_string() == want {
                return true;
            }
        }
    }
    false
}

/// Script type from a BIP32 path's purpose component (44 legacy / 49 nested
/// / 84 native; default native). Used by the Ledger path, which signs at a
/// derivation path and lets the host derive the bound address.
pub(crate) fn script_type_from_path(path: &str) -> BtcMsgScriptType {
    let purpose = path.split('/').find_map(|seg| {
        seg.chars()
            .take_while(|c| c.is_ascii_digit())
            .collect::<String>()
            .parse::<u32>()
            .ok()
    });
    match purpose {
        Some(44) => BtcMsgScriptType::Legacy,
        Some(49) => BtcMsgScriptType::NestedSegwit,
        _ => BtcMsgScriptType::NativeSegwit,
    }
}

/// Recover the address that a 65-byte Electrum signature ([header || r || s])
/// binds to, for `script_type` on `net`. The Ledger device returns the
/// signature but not the address, so the host derives it here (and it matches
/// what `btc_verify_message` will accept).
pub(crate) fn recover_address(
    message: &[u8],
    packed: &[u8],
    script_type: BtcMsgScriptType,
    net: BtcMsgNetwork,
) -> Option<String> {
    if packed.len() != 65 || packed[0] < 27 {
        return None;
    }
    let recid = RecoveryId::from_i32(((packed[0] - 27) & 0x03) as i32).ok()?;
    let recsig = RecoverableSignature::from_compact(&packed[1..65], recid).ok()?;
    let text = std::str::from_utf8(message).ok()?;
    let hash = signed_msg_hash(text);
    let msg = Message::from_digest(hash.to_byte_array());
    let secp = Secp256k1::verification_only();
    let pk = secp.recover_ecdsa(&msg, &recsig).ok()?;
    Some(address_for(&pk, script_type, network(net)).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    // A fixed secret key -> deterministic address + round-trip per type.
    fn sk_bytes() -> Vec<u8> {
        vec![0x07u8; 32]
    }

    #[test]
    fn sign_then_verify_roundtrips_all_types() {
        for ty in [
            BtcMsgScriptType::Legacy,
            BtcMsgScriptType::NestedSegwit,
            BtcMsgScriptType::NativeSegwit,
        ] {
            for net in [
                BtcMsgNetwork::Mainnet,
                BtcMsgNetwork::Testnet,
                BtcMsgNetwork::Signet,
            ] {
                let signed = btc_sign_message(sk_bytes(), "hello maknoon".into(), ty, net).unwrap();
                assert!(btc_verify_message(
                    signed.address.clone(),
                    "hello maknoon".into(),
                    signed.signature.clone()
                ));
                // Tampered message must fail.
                assert!(!btc_verify_message(
                    signed.address,
                    "hello maknoo".into(),
                    signed.signature
                ));
            }
        }
    }

    // Cross-platform known-answer vectors: the same corpus iOS + Android assert,
    // so all three implementations (and WalletCore on the apps) must produce
    // these byte-identical signatures + addresses. Regenerate via the kat_gen
    // integration test. ETH vectors are asserted on the platforms (no ETH
    // signing in this core); here we pin the Bitcoin BIP-137 vectors.
    const KAT: &str = include_str!("../test-vectors/message-signing-kat.json");

    fn script_type(s: &str) -> BtcMsgScriptType {
        match s {
            "legacy" => BtcMsgScriptType::Legacy,
            "nestedSegwit" => BtcMsgScriptType::NestedSegwit,
            "nativeSegwit" => BtcMsgScriptType::NativeSegwit,
            other => panic!("unknown scriptType {other}"),
        }
    }
    fn net(s: &str) -> BtcMsgNetwork {
        match s {
            "mainnet" => BtcMsgNetwork::Mainnet,
            "testnet3" => BtcMsgNetwork::Testnet,
            "signet" => BtcMsgNetwork::Signet,
            other => panic!("unknown network {other}"),
        }
    }

    #[test]
    fn bitcoin_kat_corpus_matches() {
        let v: serde_json::Value = serde_json::from_str(KAT).unwrap();
        let vectors = v["bitcoin"].as_array().unwrap();
        assert!(!vectors.is_empty(), "empty KAT corpus");
        for vec in vectors {
            let sk = hex::decode(vec["secretKeyHex"].as_str().unwrap()).unwrap();
            let msg = vec["message"].as_str().unwrap().to_string();
            let ty = script_type(vec["scriptType"].as_str().unwrap());
            let n = net(vec["network"].as_str().unwrap());
            let want_addr = vec["expectedAddress"].as_str().unwrap();
            let want_sig = vec["expectedSignature"].as_str().unwrap();

            let signed = btc_sign_message(sk, msg.clone(), ty, n).unwrap();
            assert_eq!(signed.address, want_addr, "address mismatch for {vec}");
            assert_eq!(signed.signature, want_sig, "signature mismatch for {vec}");
            // The frozen signature must verify against the frozen address.
            assert!(
                btc_verify_message(want_addr.to_string(), msg, want_sig.to_string()),
                "verify failed for {vec}"
            );
        }
    }
}
