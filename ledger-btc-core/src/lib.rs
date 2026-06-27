// ledger-btc-core: cross-platform Ledger Bitcoin signing client.
//
// The protocol heavy-lifting (APDU framing, PSBT v0→v2, Merkleized
// client commands, wallet policies, Taproot, MuSig2) is provided
// by LedgerHQ's `ledger_bitcoin_client` crate. This crate wraps
// that with:
//
//   - A foreign callback interface (Transport) so iOS / Android
//     code can inject their BLE/USB stack.
//   - UniFFI-friendly value types (records / enums) that round-trip
//     cleanly through Swift and Kotlin.
//   - Base64 PSBT in/out so the host app only marshals strings,
//     not Rust types.
//
// Public API surface is documented in client.rs.

mod adapter;
mod client;
mod error;
mod message;
mod transport;
mod types;

pub use client::LedgerBitcoinClient;
pub use error::LedgerError;
pub use message::{
    btc_sign_message, btc_verify_message, BtcMsgError, BtcMsgNetwork, BtcMsgScriptType,
    BtcSignedMessage,
};
pub use transport::{ExchangeResponse, Transport, TransportError};
pub use types::{LedgerBitcoinNetwork, RegisteredPolicy, WalletPolicy};

uniffi::setup_scaffolding!();
