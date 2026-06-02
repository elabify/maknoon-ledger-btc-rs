// MockTransport: canned APDU responses so the emulator can exercise
// the full Compose + UniFFI + Rust + Kotlin stack without a Ledger
// Nano X attached. Real BLE testing requires a physical Android
// device (the Android Emulator does not bridge host Bluetooth into
// the guest VM in any reliable way).
//
// Production apps replace this with BLETransport (see week 4 part B).
package com.benjaminchodroff.ledgerbtcexample

import uniffi.ledger_btc_core.ExchangeResponse
import uniffi.ledger_btc_core.Transport

@OptIn(kotlin.ExperimentalUnsignedTypes::class)
class MockTransport : Transport {
    override suspend fun exchange(apdu: ByteArray): ExchangeResponse {
        val cla = apdu.getOrNull(0)?.toInt()?.and(0xff)
        val ins = apdu.getOrNull(1)?.toInt()?.and(0xff)

        // GET_MASTER_FINGERPRINT (CLA=0xE1 INS=0x05): return a
        // synthetic 4-byte fingerprint so the UI can render
        // something recognizable.
        if (cla == 0xE1 && ins == 0x05) {
            return ExchangeResponse(
                statusWord = 0x9000U,
                data = byteArrayOf(
                    0xDE.toByte(), 0xAD.toByte(), 0xBE.toByte(), 0xEF.toByte()
                )
            )
        }
        // GET_EXTENDED_PUBKEY (CLA=0xE1 INS=0x00): return a fake
        // (but realistically-shaped) xpub so the calling code's
        // ASCII parse succeeds. The string isn't a valid BIP-32
        // xpub by checksum; if upstream rejects it on parse we'll
        // see Protocol error in the UI, which is fine for the
        // emulator demo (proves the wiring).
        if (cla == 0xE1 && ins == 0x00) {
            val fakeXpub = "xpub6CUGRUonZSQ4TWtTMmzXdrXDtypWKiKrhko4egpiMZbpiaQL2jkwSB1icqYh2cfDfVxdx4df189oLKnC5fSwqPfgyP3hooxujYzAu3fDVmz"
            return ExchangeResponse(
                statusWord = 0x9000U,
                data = fakeXpub.toByteArray(Charsets.US_ASCII)
            )
        }

        // Anything else: a tame error the UI surfaces nicely.
        return ExchangeResponse(
            statusWord = 0x6A82U,  // NotSupported, signals to caller
            data = byteArrayOf()
        )
    }
}
