#!/usr/bin/env bash
# Build the macOS test CLI by direct swiftc invocation. Keeps the
# example free of an SPM Package.swift dance for binary library
# linking. Run `./Examples/macos-cli/build.sh` from the repo root
# OR from this directory; both work.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
cd "$ROOT"

OUT="$HERE/ledger-cli"
LIB_DIR="$ROOT/target/release"
HEADERS_DIR="$ROOT/ios/bindings/headers"
GENERATED_SWIFT="$ROOT/ios/bindings/ledger_btc_core.swift"

# Make sure the prereqs exist.
if [[ ! -f "$LIB_DIR/libledger_btc_core.a" ]]; then
    echo "missing $LIB_DIR/libledger_btc_core.a"
    echo "build it first with:  cargo build --release -p ledger-btc-core"
    exit 1
fi
if [[ ! -f "$GENERATED_SWIFT" ]]; then
    echo "missing $GENERATED_SWIFT"
    echo "build it first with:  make ios   (or just regenerate bindings)"
    exit 1
fi

echo "[swift] compiling $OUT"
swiftc -O \
    -I "$HEADERS_DIR" \
    -Xcc -fmodule-map-file="$HEADERS_DIR/module.modulemap" \
    -framework CoreBluetooth \
    -L "$LIB_DIR" \
    -lledger_btc_core \
    "$GENERATED_SWIFT" \
    "$HERE/Sources/CLI.swift" \
    "$HERE/Sources/BLETransport.swift" \
    -o "$OUT"

echo "[swift] done: $OUT"
