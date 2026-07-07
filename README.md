# ledger-btc-rs

> **Status: pre-1.0, Week 4 partial (2026-05-23).** Same Rust source
> drives iOS (validated end-to-end on real iPhone signing testnet
> PSBT), macOS (validated end-to-end via the CLI), and Android
> (.aar builds, Compose example app builds, Kotlin BLE transport
> ported but untested without an Android device). Conformance
> harness runs 3 captured fixtures byte-for-byte through
> `MockTransport`. Week 5 next: CI integration.

A Rust core + UniFFI bindings for talking to the **Ledger Bitcoin
app** from iOS and Android. Built on top of LedgerHQ's official
[`ledger_bitcoin_client`](https://github.com/LedgerHQ/app-bitcoin-new/tree/master/bitcoin_client_rs)
Rust crate (which already implements the SIGN_PSBT v2 protocol,
Merkleized client commands, Taproot, MuSig2, and wallet policies),
plus a thin foreign-callback transport so the host platform owns
its own BLE / USB stack.

Single source of truth, two artifacts:

```
ledger-btc-rs/  (this repo)
   ├── ledger-btc-core  ←  Rust crate
   ├── ios              ←  build-xcframework.sh → LedgerBtcCore.xcframework
   └── android          ←  build-aar.sh → ledger-btc-core.aar
```

Script types by purpose (BIP44 / BIP49 / BIP84), hidden (passphrase) wallets, and
custom / alternative derivation paths are all supported (a path override flows
through the signing calls). The Trezor counterpart across all four chains is
`trezor-core-rs` (one unified crate).

## Design pillars

1. **Don't reimplement.** `ledger_bitcoin_client` v0.6.2 (pinned)
   handles the protocol. We wrap; we don't fork.
2. **Audit surface = Ledger device protocol only.** No BDK
   dependency. PSBT construction lives elsewhere (bdk-ffi in the
   host app). Bank pen-testers see only signing-path code.
3. **Native owns transport.** BLE GATT I/O, Ledger 5-byte framing,
   keep-alive heartbeat, MTU chunking — all on the Swift / Kotlin
   side. Rust gets complete APDUs in, complete responses out.
4. **Async end-to-end.** UniFFI callback interfaces are async; the
   Swift / Kotlin transport implementations are `async`/`suspend`
   functions; the Rust client is `async` throughout.
5. **Conformance tested.** Every release runs golden APDU vectors
   captured from a real device through a MockTransport and asserts
   byte-for-byte fidelity. Catches drift from upstream and from
   firmware.

## Building

### Prerequisites

- Rust stable (whatever your toolchain picks up; pinned to an
  exact version pre-release).
- For iOS builds: `make setup-ios-targets` once per machine.
- For Android builds: `make setup-android-targets` once, plus
  Android NDK r26+ exported as `ANDROID_NDK_HOME`.

### Common targets

```sh
make            # fmt-check + clippy + test (CI default)
make test       # cargo test only
make fmt        # cargo fmt --all
make clippy     # cargo clippy with -D warnings
make ios        # produces ios/LedgerBtcCore.xcframework
make android    # produces android/build/outputs/aar/ledger-btc-core-release.aar
make clean      # cargo clean + remove generated artifacts
```

## Public API

```rust
// One client per device session.
let client = LedgerBitcoinClient::new(my_transport);

let fingerprint: Vec<u8>     = client.get_master_fingerprint().await?;
let xpub: String             = client.get_extended_pubkey("m/84'/0'/0'".into(), false).await?;
let signed_psbt_base64: String = client.sign_psbt(unsigned_b64, policy).await?;
let registered: RegisteredPolicy = client.register_wallet(custom_policy).await?;
let address: String          = client.get_wallet_address(policy, 0, 0, true).await?;
```

After UniFFI binding generation, the Swift API is identical except
methods are `async throws`, types are Swift records, and the
caller injects a `Transport` conforming to the generated protocol.

## Repo layout

```
ledger-btc-rs/
├── Cargo.toml                  workspace
├── Cargo.lock                  pinned dep tree (commit this)
├── rust-toolchain.toml         channel pin
├── Makefile                    `make ios` / `make android` / `make test`
├── ledger-btc-core/
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs
│   │   ├── client.rs           LedgerBitcoinClient
│   │   ├── transport.rs        Transport callback trait
│   │   ├── types.rs            WalletPolicy, RegisteredPolicy, Network
│   │   └── error.rs            LedgerError
│   └── tests/
│       ├── conformance.rs      golden-vector replay
│       └── fixtures/
│           └── README.md       capture / sanitize protocol
├── ios/
│   └── build-xcframework.sh
├── android/
│   └── build-aar.sh
└── .github/workflows/ci.yml
```

## Examples

- [`Examples/macos-cli/`](Examples/macos-cli/) — `ledger-cli` with
  three subcommands (`fingerprint`, `xpub --path ...`,
  `address [--coin-type] [--account] [--change] [--index] [--display]`).
  Build via `./Examples/macos-cli/build.sh` once the Rust crate
  has been compiled for the host target. Validated against a real
  Nano X over CoreBluetooth.
- [`Examples/ios-test/`](Examples/ios-test/) — SwiftUI iOS app
  that imports `LedgerBtcCore.xcframework` and exposes the same
  operations plus a PSBT-signing pane. xcodegen-driven; see the
  example's README for build instructions.
- [`Examples/android-test/`](Examples/android-test/) — Jetpack
  Compose Android app that consumes the locally-built .aar.
  Includes a `MockTransport` for emulator iteration and a
  `BLETransport.kt` for real-device use.

## Status

Implemented and shipping in the Maknoon apps on both iOS and Android: PSBT signing
across BIP44 / BIP49 / BIP84, hidden (passphrase) wallets, and custom derivation
paths, over a BLE transport with a conformance harness that replays golden APDU
vectors through a mock transport.

## License

Apache-2.0. Matches the upstream `ledger_bitcoin_client` license,
which is the cleanest answer for downstream commercial integrators.

## Acknowledgements

- [`LedgerHQ/app-bitcoin-new`](https://github.com/LedgerHQ/app-bitcoin-new)
  for the official Rust client, Python reference, and protocol
  documentation.
- The [Mozilla UniFFI](https://github.com/mozilla/uniffi-rs)
  project for the cross-language binding generator.
