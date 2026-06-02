# Conformance fixture format

Each `.json` file in this directory is a golden vector for the
SIGN_PSBT (or other Bitcoin app) flow. The conformance harness in
`../conformance.rs` replays each fixture against a `MockTransport`
that returns the captured device responses, and asserts that every
APDU the wrapper sends matches the captured trace byte-for-byte.

## Schema

```json
{
  "name": "human-readable-fixture-name",
  "description": "what this case proves",
  "operation": "sign_psbt",
  "input": {
    "psbt_base64": "cHNidP8B...",
    "wallet_policy": {
      "name": "",
      "descriptor_template": "wpkh(@0/**)",
      "keys": ["[f5acc2fd/84'/1'/0']tpubDC..."],
      "hmac": null
    }
  },
  "expected_exchange_sequence": [
    {"direction": "send", "apdu_hex": "e10400..."},
    {"direction": "recv", "status_word": "0xE000", "data_hex": "40..."},
    {"direction": "send", "apdu_hex": "f8010001..."},
    ...
    {"direction": "recv", "status_word": "0x9000", "data_hex": ""}
  ],
  "expected_signed_psbt_base64": "cHNidP8B..."
}
```

Field notes:

- `operation`: one of `sign_psbt`, `get_master_fingerprint`,
  `get_extended_pubkey`, `register_wallet`, `get_wallet_address`.
- `direction`: `send` is host → device, `recv` is device → host.
  Each `send` represents one APDU the wrapper emits. Each `recv`
  is the canned response the mock returns next.
- `apdu_hex`: lowercase hex of the full APDU bytes (CLA INS P1 P2
  [Lc data]). No spaces.
- `status_word`: hex string for SW1 SW2, e.g. `"0x9000"`,
  `"0xE000"`, `"0x6985"` (user canceled).
- `data_hex`: hex of the response payload, excluding the trailing
  SW1 SW2. May be empty (`""`).

## Capturing a new fixture

1. Run the host app with verbose APDU logging enabled.
2. Drive the flow you want to capture against a real device.
3. Save the host's outgoing APDUs (the `>>>` lines) and incoming
   device responses (the `<<<` lines plus their SW) in order.
4. Sanitize: replace any personal device fingerprint with
   LedgerHQ's public test fingerprint `f5acc2fd`. Replace personal
   xpubs with the published test tpub
   `tpubDCtKfsNyRhULjZ9XMS4VKKtVcPdVDi8MKUbcSD9MJDyjRu1A2ND5MiipozyyspBT9bg8upEp7a8EAgFxNxXn1d7QkdbL52Ty5jiSLcxPt1P`.
5. Verify the sanitized PSBT base64 (input + expected output)
   still parses by re-running the operation against a device
   loaded with the test seed.

NOTE: never commit a fixture with a personal fingerprint or xpub.
The bank audit story rests on this.
