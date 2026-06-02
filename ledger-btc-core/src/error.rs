use thiserror::Error;

/// Errors surfaced from the public API. Designed for clean
/// marshalling through UniFFI: each variant has a `message`
/// field so Swift / Kotlin callers can show or log a useful
/// string without inspecting the variant.
#[derive(Debug, Error, uniffi::Error)]
pub enum LedgerError {
    /// The injected Transport failed (BLE disconnect, timeout,
    /// device unplugged, etc.). The host platform owns transport
    /// and supplies the description.
    #[error("transport error: {reason}")]
    Transport { reason: String },

    /// The Bitcoin app returned a non-success status word.
    /// 0x6985 is the canonical "user denied" (we surface that as
    /// `UserCanceled` instead). All other non-9000 status words
    /// map here, with the SW byte preserved for diagnostics.
    #[error("device rejected (status 0x{status_word:04X}): {reason}")]
    DeviceRejected { status_word: u16, reason: String },

    /// Input PSBT couldn't be parsed or is malformed for signing.
    #[error("invalid PSBT: {reason}")]
    InvalidPsbt { reason: String },

    /// Wallet policy fields don't form a valid descriptor or
    /// the key origin strings are malformed.
    #[error("invalid wallet policy: {reason}")]
    InvalidPolicy { reason: String },

    /// Anything unexpected in the protocol exchange that isn't
    /// covered by the more specific variants above. Includes
    /// upstream `BitcoinClientError` variants that don't map
    /// cleanly elsewhere.
    #[error("protocol error: {reason}")]
    Protocol { reason: String },

    /// The user pressed reject on the device (status word
    /// 0x6985). Special-cased because UI typically wants to
    /// distinguish "user said no" from "something broke."
    #[error("user canceled on device")]
    UserCanceled,
}

// Convenience constructors used by client.rs to keep call sites
// readable. `invalid_psbt` is added now for API stability; gets a
// real call site in week 2 when sign_psbt is wired up.
#[allow(dead_code)]
impl LedgerError {
    pub(crate) fn protocol(msg: impl Into<String>) -> Self {
        LedgerError::Protocol { reason: msg.into() }
    }

    pub(crate) fn invalid_psbt(msg: impl Into<String>) -> Self {
        LedgerError::InvalidPsbt { reason: msg.into() }
    }
}
