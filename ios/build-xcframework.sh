#!/usr/bin/env bash
# Build LedgerBtcCore.xcframework: arm64 device + arm64/x86_64 sim.
#
# Output:
#   ios/LedgerBtcCore.xcframework  — drop this into Xcode
#   ios/bindings/Swift/             — generated Swift glue
#
# Prerequisites (one-time): `make setup-ios-targets`

set -euo pipefail

CRATE=ledger-btc-core
LIB=libledger_btc_core
PROFILE=release
PROFILE_DIR=release

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Prefer the rustup-managed cargo + rustc so iOS cross-compile
# targets resolve correctly. On a typical mac dev setup Homebrew
# installs its own rustc into /opt/homebrew/bin/ that takes PATH
# priority over the rustup proxies; Homebrew's rustc doesn't ship
# iOS std libs and produces obscure "can't find crate for `core`"
# errors. Setting RUSTC explicitly forces cargo to invoke the
# rustup-managed rustc that does have the iOS sysroots.
if command -v rustup >/dev/null 2>&1; then
    CARGO="$(rustup which cargo)"
    export RUSTC="$(rustup which rustc)"
else
    CARGO="cargo"
fi
echo "[ios] using cargo: $CARGO"
echo "[ios] using rustc: ${RUSTC:-cargo-default}"

# Pin the iOS min-version so rustc AND cc-rs (secp256k1 C) agree with the app's
# deployment target; otherwise the static lib objects link with a "built for newer
# iOS version" warning.
export IPHONEOS_DEPLOYMENT_TARGET="26.0"

echo "[ios] building arm64 device"
"$CARGO" build --release -p "$CRATE" --target aarch64-apple-ios

echo "[ios] building arm64 sim"
"$CARGO" build --release -p "$CRATE" --target aarch64-apple-ios-sim

echo "[ios] building x86_64 sim"
"$CARGO" build --release -p "$CRATE" --target x86_64-apple-ios

echo "[ios] creating universal simulator slice"
mkdir -p "target/universal-sim/$PROFILE_DIR"
lipo -create \
    "target/aarch64-apple-ios-sim/$PROFILE_DIR/$LIB.a" \
    "target/x86_64-apple-ios/$PROFILE_DIR/$LIB.a" \
    -output "target/universal-sim/$PROFILE_DIR/$LIB.a"

echo "[ios] generating Swift bindings"
rm -rf ios/bindings
mkdir -p ios/bindings
"$CARGO" run --release -p "$CRATE" --bin uniffi-bindgen -- \
    generate \
    --library "target/aarch64-apple-ios/$PROFILE_DIR/$LIB.a" \
    --language swift \
    --out-dir ios/bindings

# Swift 6 language mode rejects `public static let X: <non-Sendable>`
# because it can hold mutable state across actor boundaries. UniFFI
# 0.31.1's vtable pointer declarations trip this. Mark them
# `nonisolated(unsafe)` post-generation — the pointers are
# genuinely shared and read-only at runtime (they hold the foreign
# callback dispatch table), so the suppression is correct rather
# than a workaround.
SWIFT_BINDINGS="ios/bindings/ledger_btc_core.swift"
sed -i.bak \
    -e 's/^    static let vtable:/    nonisolated(unsafe) static let vtable:/' \
    -e 's/^    static let vtablePtr:/    nonisolated(unsafe) static let vtablePtr:/' \
    "$SWIFT_BINDINGS"
rm -f "${SWIFT_BINDINGS}.bak"

# Move the generated .h + modulemap into a headers/ dir the
# xcframework expects.
mkdir -p ios/bindings/headers
mv ios/bindings/*.h ios/bindings/headers/ 2>/dev/null || true
mv ios/bindings/*.modulemap ios/bindings/headers/module.modulemap 2>/dev/null || true

echo "[ios] assembling xcframework"
rm -rf ios/LedgerBtcCore.xcframework
xcodebuild -create-xcframework \
    -library "target/aarch64-apple-ios/$PROFILE_DIR/$LIB.a" \
    -headers ios/bindings/headers \
    -library "target/universal-sim/$PROFILE_DIR/$LIB.a" \
    -headers ios/bindings/headers \
    -output ios/LedgerBtcCore.xcframework

echo "[ios] done: ios/LedgerBtcCore.xcframework"
echo "[ios] Swift glue: ios/bindings/*.swift"
