// Conformance harness for ledger-btc-core.
//
// Loads JSON fixtures from `tests/fixtures/*.json`, replays each
// against a MockTransport that asserts byte-for-byte APDU
// equality with the captured trace, then verifies the SDK
// produced the same final result.
//
// Catches:
//   1. Drift between our wrapper and the upstream
//      ledger_bitcoin_client crate.
//   2. Drift between upstream and live Bitcoin app firmware (as
//      observable in captured traces).
//   3. Regressions when bumping the upstream crate version.
//
// Fixture data files are gitignored. Capture locally with
// `Examples/macos-cli/ledger-cli <subcommand> --capture <path>`.
// See `tests/fixtures/README.md` for the schema.

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::sync::Mutex;

use ledger_btc_core::{
    ExchangeResponse, LedgerBitcoinClient, Transport, TransportError, WalletPolicy,
};
use serde::Deserialize;

// MARK: -- MockTransport

/// In-memory transport that replays a captured exchange sequence.
///
/// On every `exchange` call the provided APDU must equal the next
/// captured `send` byte-for-byte, and we return the next captured
/// `recv` (status word + data). If the sequence runs out or the
/// APDU doesn't match, the test fails with a clear panic.
struct MockTransport {
    sequence: Mutex<Vec<RecordedExchange>>,
    cursor: AtomicUsize,
}

#[derive(Debug, Clone)]
struct RecordedExchange {
    send_apdu: Vec<u8>,
    recv_status: u16,
    recv_data: Vec<u8>,
}

impl MockTransport {
    fn new(exchanges: Vec<RecordedExchange>) -> Self {
        Self {
            sequence: Mutex::new(exchanges),
            cursor: AtomicUsize::new(0),
        }
    }

    fn assert_drained(&self) {
        let consumed = self.cursor.load(Ordering::SeqCst);
        let total = self.sequence.lock().unwrap().len();
        assert_eq!(
            consumed, total,
            "fixture had {total} exchanges captured but client only consumed {consumed}"
        );
    }
}

#[async_trait::async_trait]
impl Transport for MockTransport {
    async fn exchange(&self, apdu: Vec<u8>) -> Result<ExchangeResponse, TransportError> {
        let i = self.cursor.fetch_add(1, Ordering::SeqCst);
        let seq = self.sequence.lock().unwrap();
        let expected = seq.get(i).cloned().unwrap_or_else(|| {
            panic!(
                "client emitted more APDUs than the fixture captured ({} > {}). Excess APDU: {}",
                i + 1,
                seq.len(),
                hex::encode(&apdu)
            )
        });
        drop(seq);
        assert_eq!(
            apdu,
            expected.send_apdu,
            "APDU at index {i} did not match fixture. expected={} actual={}",
            hex::encode(&expected.send_apdu),
            hex::encode(&apdu)
        );
        Ok(ExchangeResponse {
            status_word: expected.recv_status,
            data: expected.recv_data,
        })
    }
}

// MARK: -- Fixture schema (matches Examples/macos-cli `--capture` output)

#[derive(Debug, Deserialize)]
struct Fixture {
    #[allow(dead_code)] // surfaced in test names later
    name: String,
    operation: String,
    input: serde_json::Value,
    expected_exchange_sequence: Vec<ExchangeRecord>,
    expected_result: serde_json::Value,
}

#[derive(Debug, Deserialize)]
struct ExchangeRecord {
    direction: String,
    #[serde(default)]
    apdu_hex: Option<String>,
    #[serde(default)]
    status_word: Option<String>,
    #[serde(default)]
    data_hex: Option<String>,
}

impl Fixture {
    fn to_pairs(&self) -> Vec<RecordedExchange> {
        let mut out = Vec::new();
        let mut i = 0;
        let records = &self.expected_exchange_sequence;
        while i < records.len() {
            let send = &records[i];
            assert_eq!(send.direction, "send", "fixture out of order at index {i}");
            let recv = records.get(i + 1).expect("fixture truncated mid-pair");
            assert_eq!(
                recv.direction, "recv",
                "fixture out of order: send not followed by recv at index {i}"
            );
            let send_apdu = hex::decode(send.apdu_hex.as_ref().expect("missing apdu_hex"))
                .expect("apdu_hex was not valid hex");
            let recv_status = u16::from_str_radix(
                recv.status_word
                    .as_ref()
                    .expect("missing status_word")
                    .trim_start_matches("0x"),
                16,
            )
            .expect("status_word was not valid hex");
            let recv_data = hex::decode(recv.data_hex.as_ref().expect("missing data_hex"))
                .expect("data_hex was not valid hex");
            out.push(RecordedExchange {
                send_apdu,
                recv_status,
                recv_data,
            });
            i += 2;
        }
        out
    }
}

// MARK: -- Operation dispatch + replay

async fn replay(fixture: &Fixture) {
    let mock = Arc::new(MockTransport::new(fixture.to_pairs()));
    let client = LedgerBitcoinClient::new(mock.clone());
    match fixture.operation.as_str() {
        "fingerprint" => {
            let fp = client
                .get_master_fingerprint()
                .await
                .expect("get_master_fingerprint failed");
            let actual_hex = fp.iter().map(|b| format!("{b:02x}")).collect::<String>();
            let expected_hex = fixture
                .expected_result
                .as_str()
                .expect("expected_result must be a string for fingerprint");
            assert_eq!(
                actual_hex, expected_hex,
                "fingerprint mismatch in fixture '{}'",
                fixture.name
            );
        }
        "xpub" => {
            let path = fixture.input["path"]
                .as_str()
                .expect("xpub fixture missing input.path")
                .to_string();
            let display = fixture.input["display"].as_bool().unwrap_or(false);
            let xpub = client
                .get_extended_pubkey(path, display)
                .await
                .expect("get_extended_pubkey failed");
            let expected = fixture
                .expected_result
                .as_str()
                .expect("expected_result must be a string for xpub");
            assert_eq!(
                xpub, expected,
                "xpub mismatch in fixture '{}'",
                fixture.name
            );
        }
        "sign_psbt" => {
            let psbt = fixture.input["psbt_base64"]
                .as_str()
                .expect("sign_psbt fixture missing input.psbt_base64")
                .to_string();
            let coin_type = fixture.input["coin_type"]
                .as_u64()
                .expect("sign_psbt fixture missing coin_type") as u32;
            let account = fixture.input["account"]
                .as_u64()
                .expect("sign_psbt fixture missing account") as u32;

            // The capture trace from the macOS CLI's sign
            // subcommand includes the fingerprint + xpub probes
            // before the SIGN_PSBT APDU. Replay them in the same
            // order so the mock's send-expected sequence matches.
            let fp = client
                .get_master_fingerprint()
                .await
                .expect("get_master_fingerprint failed");
            let fingerprint_hex = fp.iter().map(|b| format!("{b:02x}")).collect::<String>();
            let xpub = client
                .get_extended_pubkey(format!("m/84'/{coin_type}'/{account}'"), false)
                .await
                .expect("get_extended_pubkey failed");
            let key_origin = format!("[{fingerprint_hex}/84'/{coin_type}'/{account}']{xpub}");
            let policy = WalletPolicy {
                name: "".into(),
                descriptor_template: "wpkh(@0/**)".into(),
                keys: vec![key_origin],
                hmac: None,
            };
            let signed = client
                .sign_psbt(psbt, policy)
                .await
                .expect("sign_psbt failed");
            let expected = fixture
                .expected_result
                .as_str()
                .expect("expected_result must be a string for sign_psbt");
            assert_eq!(
                signed, expected,
                "signed PSBT mismatch in fixture '{}'",
                fixture.name
            );
        }
        "address" => {
            let coin_type = fixture.input["coin_type"]
                .as_u64()
                .expect("address fixture missing coin_type") as u32;
            let account = fixture.input["account"]
                .as_u64()
                .expect("address fixture missing account") as u32;
            let change = fixture.input["change"]
                .as_u64()
                .expect("address fixture missing change") as u32;
            let index = fixture.input["index"]
                .as_u64()
                .expect("address fixture missing index") as u32;
            let display = fixture.input["display"].as_bool().unwrap_or(false);

            // Address fixtures also need the device-derived
            // fingerprint and xpub for the policy. Both are
            // captured in the trace's first two exchange responses,
            // but to keep the harness narrow we ask the client
            // again (which the mock dutifully replays).
            let fp = client
                .get_master_fingerprint()
                .await
                .expect("get_master_fingerprint failed");
            let fingerprint_hex = fp.iter().map(|b| format!("{b:02x}")).collect::<String>();
            let xpub = client
                .get_extended_pubkey(format!("m/84'/{coin_type}'/{account}'"), false)
                .await
                .expect("get_extended_pubkey failed");
            let key_origin = format!("[{fingerprint_hex}/84'/{coin_type}'/{account}']{xpub}");
            let policy = WalletPolicy {
                name: "".into(),
                descriptor_template: "wpkh(@0/**)".into(),
                keys: vec![key_origin],
                hmac: None,
            };
            let addr = client
                .get_wallet_address(policy, change, index, display)
                .await
                .expect("get_wallet_address failed");
            let expected = fixture
                .expected_result
                .as_str()
                .expect("expected_result must be a string for address");
            assert_eq!(
                addr, expected,
                "address mismatch in fixture '{}'",
                fixture.name
            );
        }
        other => panic!("unsupported fixture operation '{other}'"),
    }
    mock.assert_drained();
}

// MARK: -- Tests

/// Discover and replay every fixture in `tests/fixtures/*.json`.
/// Fixtures contain personal device data so are gitignored. When
/// no fixtures are present (clean clone, CI environment), this
/// test is a no-op success.
#[tokio::test]
async fn replay_all_local_fixtures() {
    let fixtures_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    if !fixtures_dir.is_dir() {
        return;
    }
    let mut count = 0;
    for entry in fs::read_dir(&fixtures_dir).expect("failed to read fixtures dir") {
        let entry = entry.expect("failed to read fixture entry");
        let path = entry.path();
        if path.extension().and_then(|e| e.to_str()) != Some("json") {
            continue;
        }
        let raw = fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()));
        let fixture: Fixture = serde_json::from_str(&raw)
            .unwrap_or_else(|e| panic!("failed to parse {}: {e}", path.display()));
        println!(
            "replaying fixture '{}' from {}",
            fixture.name,
            path.display()
        );
        replay(&fixture).await;
        count += 1;
    }
    if count == 0 {
        eprintln!(
            "(no fixtures in {} — see tests/fixtures/README.md to capture)",
            fixtures_dir.display()
        );
    } else {
        eprintln!("replayed {count} fixture(s)");
    }
}

/// Synthetic in-code test that exercises the harness mechanism
/// without needing any captured fixture data. Validates:
///   - MockTransport correctly serves canned responses.
///   - The fixture loader parses the schema we document.
///   - The replay code path for `fingerprint` operations works.
/// Doesn't validate the SDK against any real protocol output.
#[tokio::test]
async fn harness_mechanism_synthetic_fingerprint() {
    let fake_fixture_json = r#"{
        "name": "synthetic-fingerprint",
        "operation": "fingerprint",
        "input": {},
        "expected_exchange_sequence": [
            {"direction": "send", "apdu_hex": "e105000100"},
            {"direction": "recv", "status_word": "0x9000", "data_hex": "deadbeef"}
        ],
        "expected_result": "deadbeef"
    }"#;
    let fixture: Fixture =
        serde_json::from_str(fake_fixture_json).expect("synthetic fixture should parse");
    replay(&fixture).await;
}

/// Verifies the harness FAILS LOUDLY when a fixture's APDU
/// doesn't match what the SDK actually emits. Guards against
/// silently-passing tests if our adapter changes the byte
/// encoding.
#[tokio::test]
#[should_panic(expected = "APDU at index 0 did not match fixture")]
async fn harness_rejects_mismatched_apdu() {
    let drift_fixture_json = r#"{
        "name": "synthetic-drift",
        "operation": "fingerprint",
        "input": {},
        "expected_exchange_sequence": [
            {"direction": "send", "apdu_hex": "deadbeef00"},
            {"direction": "recv", "status_word": "0x9000", "data_hex": "00000000"}
        ],
        "expected_result": "00000000"
    }"#;
    let fixture: Fixture =
        serde_json::from_str(drift_fixture_json).expect("synthetic fixture should parse");
    replay(&fixture).await;
}
