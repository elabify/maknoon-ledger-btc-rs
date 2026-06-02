/// Bitcoin network selector. Maps to BIP-44 coin type 0 / 1 inside
/// wallet-policy key origin strings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum LedgerBitcoinNetwork {
    /// Mainnet. BIP-44 coin type 0. xpub / ypub / zpub.
    Mainnet,
    /// Testnet, signet, regtest. BIP-44 coin type 1.
    /// tpub / upub / vpub.
    Testnet,
}

#[allow(dead_code)]
impl LedgerBitcoinNetwork {
    // BIP-44 coin type, embedded in key-origin strings inside
    // wallet policies. Real call site lands in week 2's
    // sign_psbt wiring.
    pub(crate) fn coin_type(self) -> u32 {
        match self {
            LedgerBitcoinNetwork::Mainnet => 0,
            LedgerBitcoinNetwork::Testnet => 1,
        }
    }
}

/// A descriptor-based wallet policy as understood by the Ledger
/// Bitcoin app. Default (single-sig BIP-84 / -86) policies have an
/// empty `name` and `None` `hmac`. User-registered policies (e.g.
/// custom multisig) carry the device HMAC returned by
/// `register_wallet`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct WalletPolicy {
    /// Display name. MUST be empty for default policies; up to 16
    /// ASCII characters for registered policies.
    pub name: String,
    // Descriptor template, e.g. `wpkh(@0/<star><star>)` for single-sig
    // native SegWit (substitute `**` for `<star><star>`). `@N`
    // placeholders refer to entries in `keys`. (Doc comment held
    // back to a line comment so generated Swift bindings don't
    // misparse the nested `/**` from "**)" as a comment terminator.)
    pub descriptor_template: String,
    /// Key origin strings, one per `@N` placeholder. Each is of
    /// the form `[<fingerprint>/<path>]<xpub|tpub>`, using `'`
    /// for hardened derivations.
    pub keys: Vec<String>,
    /// 32-byte device HMAC. `None` for default policies (the
    /// device recognises them by canonical id). `Some` for
    /// user-registered policies.
    pub hmac: Option<Vec<u8>>,
}

/// Returned by `register_wallet`. Persist both fields and pass
/// them back as `WalletPolicy.hmac` on subsequent calls so the
/// device skips the re-registration prompt.
#[derive(Debug, Clone, uniffi::Record)]
pub struct RegisteredPolicy {
    /// 32-byte canonical walletId.
    pub id: Vec<u8>,
    /// 32-byte device HMAC over the policy's serialization.
    pub hmac: Vec<u8>,
}
