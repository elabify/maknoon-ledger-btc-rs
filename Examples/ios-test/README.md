# LedgerBtcExample (iOS test app)

SwiftUI iOS app that imports `LedgerBtcCore.xcframework` and lets
you exercise the public API against a real Ledger Nano X over BLE.

## What it does

A single screen with five sections:

- **Status** — current state of the last operation.
- **Configuration** — mainnet / testnet, account index.
- **Device** — Connect button that does `getMasterFingerprint`
  followed by `getExtendedPubkey` for the selected account.
- **Address derivation** — `getWalletAddress` with default BIP-84
  single-sig policy, with or without on-device confirmation.
- **Sign PSBT** — paste a base64 v0 PSBT, tap Sign, confirm on
  device. Output is the signed v0 PSBT base64.

## Prerequisites

- macOS with Xcode 15+ (Xcode 26 has been validated).
- An iPhone with iOS 17+ (BLE is required; the Simulator has no
  Bluetooth radio so this app is device-only).
- An Apple Developer account (the free personal team is fine).
- `LedgerBtcCore.xcframework` already built. From the repo root:
  ```sh
  make ios
  ```
- `xcodegen` installed (`brew install xcodegen`).

## One-time setup

```sh
cd Examples/ios-test
xcodegen
open LedgerBtcExample.xcodeproj
```

In Xcode:

1. Select the `LedgerBtcExample` target in the project navigator.
2. **Signing & Capabilities** tab → set **Team** to your Apple
   Developer team (or "Personal Team").
3. Adjust **Bundle Identifier** if `com.benjaminchodroff.example.LedgerBtcExample`
   conflicts with anything already provisioned. Anything globally
   unique works.

## Build and run on iPhone

1. Connect your iPhone via USB or wirelessly via Xcode → Window →
   Devices and Simulators.
2. Select the iPhone as the run destination (top toolbar).
3. **Pair the Ledger Nano X** with the iPhone first via iOS
   **Settings → Bluetooth**. The app does NOT initiate OS-level
   pairing; it reuses whatever pairing iOS already has.
4. Unlock the Ledger, open the **Bitcoin** app on it.
5. Cmd+R to build + install + launch.
6. On first launch, iOS will ask for Bluetooth permission. Allow.
7. Tap **Connect + load fingerprint / xpub**.

Expected first-time flow:

- Status: `Connecting + reading fingerprint and xpub`
- After ~2-5 seconds: fingerprint appears (8 lowercase hex chars)
  and the account xpub fills in below.
- Status: `Done.`

If iOS prompts to pair the Ledger Nano X mid-flow, accept. The
six-digit code on the device screen should match the iPhone's.

## Troubleshooting

- **"Bluetooth permission denied"** — Settings → LedgerBtcExample →
  Bluetooth → enable.
- **"transport disconnected" during connect** — usually stale iOS
  BLE pairing. Settings → Bluetooth → tap the (i) next to the
  Nano X → **Forget This Device**. Then re-pair via Settings →
  Bluetooth and retry.
- **Status word 0x6A82 (NotSupported)** for testnet derivations —
  the device has the mainnet **Bitcoin** app open. For testnet,
  install **Bitcoin Test** via Ledger Live → My Ledger → App
  catalog, then open it on the device.
- **Status word 0x6985 (user denied)** — you (or someone) hit the
  reject button on the device. Repeat the action.

## Why this exists

The macOS CLI ([`Examples/macos-cli/`](../macos-cli/)) validates
that the SDK works against a real device on the desktop. This
example is the iOS equivalent: same Rust core, same Swift
bindings, same BLE transport implementation (CoreBluetooth API is
identical across iOS and macOS). Running this app on your iPhone
is the end-to-end proof that ledger-btc-core is ready to be
embedded into a real iOS Bitcoin wallet.

After this works, the Android equivalent (Kotlin port of the BLE
transport against the same Rust core) is mostly mechanical.
