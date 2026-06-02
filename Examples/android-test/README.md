# LedgerBtcExample (Android test app)

Jetpack Compose Android app that consumes
`../../android/library/build/outputs/aar/library-release.aar` and
exposes the Ledger BTC SDK's API through a small UI.

## What it does

- Loads the locally-built `.aar` (your Rust core + UniFFI Kotlin
  bindings + JNI libs for arm64-v8a, armeabi-v7a, x86_64, x86).
- Wires a `MockTransport` by default, which returns canned APDU
  responses so the entire stack runs in the Android Emulator
  without a Ledger Nano X attached. The emulator does not bridge
  host Bluetooth into the guest in any reliable way, so a real
  device is the only path to BLE testing.
- Includes a `BLETransport.kt` implementation against Android's
  `BluetoothLeScanner` + `BluetoothGatt`. Mechanically correct,
  mirrors the verified iOS/macOS Swift transport, but **untested
  on hardware** (Week 4 was scoped without an Android device).

## Prerequisites

1. macOS with Android Studio (Hedgehog or later), the API 34 SDK
   image, and the NDK installed.
2. JDK 17 (Homebrew: `brew install openjdk@17`; AGP doesn't support
   JDK 22+ as of 2026-05).
3. The library .aar built first:
   ```sh
   cd ~/workspace/ledger-btc-rs
   make android   # produces android/library/build/outputs/aar/library-release.aar
   ```
4. (Optional) An Android Emulator AVD with API 34, arm64-v8a image
   (faster on Apple Silicon than x86_64).

## Build the APK

```sh
cd ~/workspace/ledger-btc-rs/Examples/android-test
./gradlew :app:assembleDebug
# → app/build/outputs/apk/debug/app-debug.apk
```

Environment variables required (the build script sets these if
they're not in your shell env):

- `ANDROID_HOME` = `$HOME/Library/Android/sdk`
- `JAVA_HOME` = the JDK 17 install (Homebrew default:
  `/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home`)

## Run in the emulator

```sh
# Boot your AVD (replace name as needed)
~/Library/Android/sdk/emulator/emulator -avd Pixel_7_API_34 &

# Install the APK
~/Library/Android/sdk/platform-tools/adb install -r \
    ~/workspace/ledger-btc-rs/Examples/android-test/app/build/outputs/apk/debug/app-debug.apk

# Launch
~/Library/Android/sdk/platform-tools/adb shell am start \
    -n com.benjaminchodroff.ledgerbtcexample/.MainActivity
```

Expected behavior in the emulator:

- App opens, shows "Idle. Tap Connect..."
- Tap **Connect (mock)** → `MockTransport` returns canned bytes →
  the UI displays a fake fingerprint (`deadbeef`) and a fake xpub.
- Demonstrates that the entire Compose ↔ UniFFI ↔ Rust ↔ Kotlin
  stack is wired correctly, without needing real BLE.

## Switching to real BLE

When you eventually have an Android phone:

1. Edit `MainActivity.kt` → `LedgerViewModel`:
   ```kotlin
   // Replace this line:
   private val transport = MockTransport()
   // With this:
   private val transport = BLETransport(context = applicationContext)
   ```
   (Adjust the constructor to accept the Android `Context` from
   the Activity; pattern is the same as any other Android-context
   ViewModel.)
2. Pair the Ledger Nano X via the phone's **Settings → Bluetooth**
   FIRST. The transport reuses the OS-level pairing rather than
   initiating its own.
3. Grant **Nearby devices** runtime permission (Android 12+
   requirement) when the app prompts.
4. Open the Bitcoin app on the device.
5. Tap **Connect**.
