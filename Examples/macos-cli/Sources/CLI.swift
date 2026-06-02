// Minimal macOS CLI exercising ledger-btc-core against a real Ledger
// Nano X over Bluetooth.
//
// Subcommands:
//   fingerprint         Print master pubkey fingerprint (4 hex bytes).
//   xpub --path <path>  Print BIP-32 extended pubkey at given path.
//                       Optional --display prompts on-device.
//   address             Print a BIP-84 single-sig address. Optional
//                       --coin-type / --account / --change / --index
//                       (all default 0). Pass --display to confirm
//                       on-device.
//
// Prerequisites:
//   - Ledger Nano X paired via System Settings > Bluetooth FIRST.
//   - Unlock device, open Bitcoin app (or Bitcoin Test for testnet).

import CoreBluetooth
import Foundation

@main
struct CLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let sub = args.first else {
            printUsage()
            exit(1)
        }
        do {
            switch sub {
            case "fingerprint":
                try await runFingerprint(args: Array(args.dropFirst()))
            case "xpub":
                try await runXpub(args: Array(args.dropFirst()))
            case "address":
                try await runAddress(args: Array(args.dropFirst()))
            case "sign":
                try await runSign(args: Array(args.dropFirst()))
            case "register":
                try await runRegister(args: Array(args.dropFirst()))
            case "-h", "--help", "help":
                printUsage()
            default:
                FileHandle.standardError.write("unknown subcommand: \(sub)\n".data(using: .utf8)!)
                printUsage()
                exit(1)
            }
        } catch {
            FileHandle.standardError.write("FAIL: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(2)
        }
    }

    // MARK: -- subcommands

    static func runFingerprint(args: [String] = []) async throws {
        let parsed = try parseArgs(args, allowed: ["capture"])
        let (transport, client) = try await openClient(capturing: parsed["capture"] != nil)
        FileHandle.standardError.write("Requesting master fingerprint...\n".data(using: .utf8)!)
        let fp = try await client.getMasterFingerprint()
        let hex = fp.map { String(format: "%02x", $0) }.joined()
        print(hex)
        try writeFixtureIfRequested(
            path: parsed["capture"],
            name: "fingerprint",
            operation: "fingerprint",
            input: [:],
            transport: transport,
            expectedResult: .string(hex)
        )
    }

    static func runXpub(args: [String]) async throws {
        let parsed = try parseArgs(args, allowed: ["path", "display", "capture"])
        guard let path = parsed["path"] else {
            throw CLIError("xpub requires --path (e.g. \"m/84'/1'/0'\")")
        }
        let display = parsed["display"] == "true" || parsed["display"] == "1"

        let (transport, client) = try await openClient(capturing: parsed["capture"] != nil)
        FileHandle.standardError.write(
            "Requesting xpub at \(path)\(display ? " (confirm on device)" : "")...\n"
                .data(using: .utf8)!
        )
        let xpub = try await client.getExtendedPubkey(path: path, display: display)
        print(xpub)
        try writeFixtureIfRequested(
            path: parsed["capture"],
            name: "xpub-\(path)",
            operation: "xpub",
            input: ["path": .string(path), "display": .bool(display)],
            transport: transport,
            expectedResult: .string(xpub)
        )
    }

    static func runAddress(args: [String]) async throws {
        let parsed = try parseArgs(
            args,
            allowed: ["coin-type", "account", "change", "index", "display", "capture", "policy"]
        )
        let change = UInt32(parsed["change"] ?? "0") ?? 0
        let index = UInt32(parsed["index"] ?? "0") ?? 0
        let display = parsed["display"] == "true" || parsed["display"] == "1"
        guard change == 0 || change == 1 else {
            throw CLIError("--change must be 0 or 1")
        }

        let (transport, client) = try await openClient(capturing: parsed["capture"] != nil)

        // Wallet policy: either loaded from --policy <file>
        // (multisig / registered) or auto-built from --coin-type /
        // --account (default BIP-84 single-sig).
        let policy: WalletPolicy
        let coinType: UInt32
        let account: UInt32
        if let policyPath = parsed["policy"] {
            policy = try readPolicyJSON(path: policyPath).toWalletPolicy()
            coinType = 0
            account = 0
            FileHandle.standardError.write(
                "Using policy '\(policy.name)' from \(policyPath)\n".data(using: .utf8)!
            )
        } else {
            coinType = UInt32(parsed["coin-type"] ?? "0") ?? 0
            account = UInt32(parsed["account"] ?? "0") ?? 0
            FileHandle.standardError.write("Fetching fingerprint and account xpub...\n".data(using: .utf8)!)
            let fpBytes = try await client.getMasterFingerprint()
            let fingerprintHex = fpBytes.map { String(format: "%02x", $0) }.joined()
            let accountPath = "m/84'/\(coinType)'/\(account)'"
            let xpub = try await client.getExtendedPubkey(path: accountPath, display: false)
            let keyOrigin = "[\(fingerprintHex)/84'/\(coinType)'/\(account)']\(xpub)"
            policy = WalletPolicy(
                name: "",
                descriptorTemplate: "wpkh(@0/**)",
                keys: [keyOrigin],
                hmac: nil
            )
        }

        FileHandle.standardError.write(
            "Requesting address at change=\(change) index=\(index)\(display ? " (confirm on device)" : "")...\n"
                .data(using: .utf8)!
        )
        let address = try await client.getWalletAddress(
            policy: policy,
            change: change,
            index: index,
            display: display
        )
        print(address)
        try writeFixtureIfRequested(
            path: parsed["capture"],
            name: "address-coin\(coinType)-acct\(account)-c\(change)-i\(index)",
            operation: "address",
            input: [
                "coin_type": .number(Double(coinType)),
                "account": .number(Double(account)),
                "change": .number(Double(change)),
                "index": .number(Double(index)),
                "display": .bool(display),
            ],
            transport: transport,
            expectedResult: .string(address)
        )
    }

    static func runSign(args: [String]) async throws {
        let parsed = try parseArgs(
            args,
            allowed: ["psbt", "coin-type", "account", "capture", "policy"]
        )
        guard var psbt = parsed["psbt"] else {
            throw CLIError("sign requires --psbt <base64>")
        }
        psbt = psbt.trimmingCharacters(in: .whitespacesAndNewlines)

        let (transport, client) = try await openClient(capturing: parsed["capture"] != nil)

        let policy: WalletPolicy
        let coinType: UInt32
        let account: UInt32
        if let policyPath = parsed["policy"] {
            policy = try readPolicyJSON(path: policyPath).toWalletPolicy()
            coinType = 0
            account = 0
            FileHandle.standardError.write(
                "Using policy '\(policy.name)' from \(policyPath)\n".data(using: .utf8)!
            )
        } else {
            coinType = UInt32(parsed["coin-type"] ?? "0") ?? 0
            account = UInt32(parsed["account"] ?? "0") ?? 0
            FileHandle.standardError.write("Fetching fingerprint and account xpub...\n".data(using: .utf8)!)
            let fpBytes = try await client.getMasterFingerprint()
            let fingerprintHex = fpBytes.map { String(format: "%02x", $0) }.joined()
            let accountPath = "m/84'/\(coinType)'/\(account)'"
            let xpub = try await client.getExtendedPubkey(path: accountPath, display: false)
            let keyOrigin = "[\(fingerprintHex)/84'/\(coinType)'/\(account)']\(xpub)"
            policy = WalletPolicy(
                name: "",
                descriptorTemplate: "wpkh(@0/**)",
                keys: [keyOrigin],
                hmac: nil
            )
        }

        FileHandle.standardError.write(
            "Sending PSBT to Ledger. Confirm the transaction on device when prompted...\n"
                .data(using: .utf8)!
        )
        let signed = try await client.signPsbt(psbtBase64: psbt, policy: policy)
        print(signed)
        try writeFixtureIfRequested(
            path: parsed["capture"],
            name: "sign-coin\(coinType)-acct\(account)",
            operation: "sign_psbt",
            input: [
                "psbt_base64": .string(psbt),
                "coin_type": .number(Double(coinType)),
                "account": .number(Double(account)),
            ],
            transport: transport,
            expectedResult: .string(signed)
        )
    }

    static func runRegister(args: [String]) async throws {
        let parsed = try parseArgsMulti(
            args,
            allowed: ["name", "template", "threshold", "sorted", "key", "output"],
            repeatable: ["key"]
        )
        let name = parsed.single["name"] ?? ""  // empty for default policies; non-empty for registered ones
        let keys = parsed.multi["key"] ?? []
        guard !keys.isEmpty else {
            throw CLIError("register requires at least one --key '[fingerprint/path]xpub' argument")
        }

        // Caller can either supply the template directly via
        // --template, or build a sortedmulti from --threshold + the
        // key count. Templates always end with `/<star><star>` so
        // address derivation uses both change branches.
        let template: String
        if let t = parsed.single["template"] {
            template = t
        } else if let thresholdStr = parsed.single["threshold"], let k = Int(thresholdStr) {
            guard k >= 1, k <= keys.count else {
                throw CLIError("--threshold \(k) is out of range for \(keys.count) keys")
            }
            let sorted = parsed.single["sorted"] == "true"
            let placeholders = (0..<keys.count).map { "@\($0)/**" }.joined(separator: ",")
            let multiKeyword = sorted ? "sortedmulti" : "multi"
            template = "wsh(\(multiKeyword)(\(k),\(placeholders)))"
        } else {
            throw CLIError("register requires either --template or --threshold")
        }

        // Registration prompts on-device for user confirmation.
        let (transport, client) = try await openClient(capturing: false)
        _ = transport  // unused; suppress unused-var if any future linter is angry

        let policy = WalletPolicy(
            name: name,
            descriptorTemplate: template,
            keys: keys,
            hmac: nil
        )

        FileHandle.standardError.write(
            "Sending policy '\(name)' to Ledger. Confirm on device when prompted...\n".data(using: .utf8)!
        )
        let registered = try await client.registerWallet(policy: policy)

        // Emit policy + HMAC as a JSON file. Subsequent `address`
        // / `sign` invocations consume this via --policy.
        let outputPath = parsed.single["output"]
            ?? (FileManager.default.currentDirectoryPath + "/registered-policy.json")
        try writePolicyJSON(
            path: outputPath,
            name: name,
            template: template,
            keys: keys,
            hmac: registered.hmac
        )
        FileHandle.standardError.write(
            "Registered. Wrote policy + HMAC to \(outputPath)\n".data(using: .utf8)!
        )
        print(registered.hmac.map { String(format: "%02x", $0) }.joined())
    }

    // MARK: -- shared helpers

    static func openClient(capturing: Bool = false) async throws -> (BLETransport, LedgerBitcoinClient) {
        let transport = BLETransport(verbose: true)
        transport.capturing = capturing
        let client = LedgerBitcoinClient(transport: transport)
        FileHandle.standardError.write("Connecting to Ledger over BLE...\n".data(using: .utf8)!)
        try await transport.connect()
        return (transport, client)
    }

    /// Minimal --key value parser. `--flag` without a value is
    /// treated as `--flag true`. `allowed` is the set of valid
    /// keys; unknown keys throw.
    static func parseArgs(_ args: [String], allowed: [String]) throws -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i < args.count {
            let token = args[i]
            guard token.hasPrefix("--") else {
                throw CLIError("unexpected positional arg: \(token)")
            }
            let key = String(token.dropFirst(2))
            guard allowed.contains(key) else {
                throw CLIError(
                    "unknown flag: --\(key). Allowed: --\(allowed.joined(separator: " --"))"
                )
            }
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                out[key] = args[i + 1]
                i += 2
            } else {
                out[key] = "true"
                i += 1
            }
        }
        return out
    }

    /// Like parseArgs but `repeatable` keys accumulate every
    /// occurrence into an array. Non-repeatable keys behave the
    /// same as the single-value parser. Used by `register` which
    /// takes one `--key` per cosigner.
    static func parseArgsMulti(
        _ args: [String],
        allowed: [String],
        repeatable: Set<String>
    ) throws -> (single: [String: String], multi: [String: [String]]) {
        var single: [String: String] = [:]
        var multi: [String: [String]] = [:]
        var i = 0
        while i < args.count {
            let token = args[i]
            guard token.hasPrefix("--") else {
                throw CLIError("unexpected positional arg: \(token)")
            }
            let key = String(token.dropFirst(2))
            guard allowed.contains(key) else {
                throw CLIError(
                    "unknown flag: --\(key). Allowed: --\(allowed.joined(separator: " --"))"
                )
            }
            let value: String
            let advance: Int
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                value = args[i + 1]
                advance = 2
            } else {
                value = "true"
                advance = 1
            }
            if repeatable.contains(key) {
                multi[key, default: []].append(value)
            } else {
                single[key] = value
            }
            i += advance
        }
        return (single, multi)
    }

    static func printUsage() {
        print("""
        ledger-cli <subcommand> [flags]

        Subcommands:
          fingerprint              Print master pubkey fingerprint.
          xpub --path <path>       Print xpub at BIP-32 path.
                                   Optional: --display
          address                  Print a BIP-84 single-sig address.
                                   Optional: --coin-type 0|1 (default 0)
                                             --account N      (default 0)
                                             --change  0|1    (default 0)
                                             --index   N      (default 0)
                                             --display
          sign --psbt <base64>     Sign a PSBT v0. Prints the signed
                                   PSBT base64 (with merged
                                   PSBT_IN_PARTIAL_SIG entries).
                                   Default BIP-84 single-sig:
                                     --coin-type 0|1 (default 0)
                                     --account N     (default 0)
                                   OR multisig / custom:
                                     --policy <path>   (json from register)
          register                 Register a wallet policy on the
                                   device. User confirms once on-
                                   device; returns the 32-byte HMAC
                                   needed for future address /
                                   sign calls. Writes
                                   {name, descriptor_template, keys,
                                   hmac_hex} JSON to --output.
                                   Required: --threshold N
                                             --key '[fp/path]xpub' (repeatable)
                                   Optional: --name STR  (default "")
                                             --sorted    (use sortedmulti)
                                             --template T (overrides --threshold)
                                             --output PATH (default ./registered-policy.json)

        All subcommands also accept:
          --capture <path>         Write a JSON fixture of the APDU
                                   exchange to <path>. Used by the
                                   ledger-btc-core conformance harness.

        Examples:
          ledger-cli fingerprint
          ledger-cli xpub --path \"m/84'/1'/0'\"
          ledger-cli address --coin-type 1 --index 0
          ledger-cli address --coin-type 0 --index 0 --display
          ledger-cli sign --psbt cHNidP8B... --coin-type 1
          ledger-cli fingerprint --capture /tmp/fp.json
          ledger-cli register --threshold 2 --sorted \\
              --key \"[fp1/48'/1'/0'/2']tpub...\" \\
              --key \"[fp2/48'/1'/0'/2']tpub...\" \\
              --key \"[fp3/48'/1'/0'/2']tpub...\" \\
              --name TestMulti --output ~/multi.json
          ledger-cli address --policy ~/multi.json --change 0 --index 0
          ledger-cli sign --policy ~/multi.json --psbt cHNidP8B...

        Prerequisites: pair the Ledger Nano X via System Settings >
        Bluetooth, unlock it, and open the Bitcoin app (or Bitcoin
        Test for testnet / --coin-type 1).
        """)
    }
}

// MARK: -- policy persistence (JSON shape consumed by --policy)

func writePolicyJSON(
    path: String,
    name: String,
    template: String,
    keys: [String],
    hmac: Data
) throws {
    let hmacHex = hmac.map { String(format: "%02x", $0) }.joined()
    var lines: [String] = []
    lines.append("{")
    lines.append("  \"name\": \"\(JSONValue.escape(name))\",")
    lines.append("  \"descriptor_template\": \"\(JSONValue.escape(template))\",")
    lines.append("  \"keys\": [")
    let keyLines = keys.map { "    \"\(JSONValue.escape($0))\"" }
    lines.append(keyLines.joined(separator: ",\n"))
    lines.append("  ],")
    lines.append("  \"hmac_hex\": \"\(hmacHex)\"")
    lines.append("}")
    try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
}

struct PolicyFile {
    let name: String
    let descriptorTemplate: String
    let keys: [String]
    let hmac: Data?
}

func readPolicyJSON(path: String) throws -> PolicyFile {
    let raw = try String(contentsOfFile: path, encoding: .utf8)
    guard let data = raw.data(using: .utf8),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw CLIError("policy file at \(path) is not valid JSON")
    }
    let name = json["name"] as? String ?? ""
    guard let template = json["descriptor_template"] as? String else {
        throw CLIError("policy file missing descriptor_template")
    }
    guard let keys = json["keys"] as? [String] else {
        throw CLIError("policy file missing or malformed keys array")
    }
    var hmac: Data? = nil
    if let hex = json["hmac_hex"] as? String, !hex.isEmpty {
        var bytes = Data()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard let byte = UInt8(hex[idx..<next], radix: 16) else {
                throw CLIError("policy hmac_hex is not valid hex")
            }
            bytes.append(byte)
            idx = next
        }
        guard bytes.count == 32 else {
            throw CLIError("policy hmac must be 32 bytes, got \(bytes.count)")
        }
        hmac = bytes
    }
    return PolicyFile(name: name, descriptorTemplate: template, keys: keys, hmac: hmac)
}

extension PolicyFile {
    func toWalletPolicy() -> WalletPolicy {
        WalletPolicy(
            name: name,
            descriptorTemplate: descriptorTemplate,
            keys: keys,
            hmac: hmac
        )
    }
}

struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ m: String) { self.message = m }
}

// MARK: -- fixture capture
//
// Writes a JSON file matching the schema documented at
// ledger-btc-core/tests/fixtures/README.md. The Rust conformance
// harness reads files of this shape, replays the recorded
// (send, recv) pairs through a MockTransport, and asserts the
// SDK emits byte-for-byte identical APDUs and produces the same
// final result.

/// Minimal JSON value used to encode operation-specific input
/// fields without a heavyweight serialization library.
enum JSONValue {
    case string(String)
    case bool(Bool)
    case number(Double)

    var jsonEncoded: String {
        switch self {
        case .string(let s): return "\"\(JSONValue.escape(s))\""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n):
            // Integers stringified as integers; doubles otherwise.
            if n.truncatingRemainder(dividingBy: 1) == 0 && abs(n) < 1e15 {
                return String(Int64(n))
            }
            return String(n)
        }
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }
}

/// If `path` is non-nil, write the captured exchange sequence
/// plus operation metadata to that path as JSON. No-op otherwise.
func writeFixtureIfRequested(
    path: String?,
    name: String,
    operation: String,
    input: [String: JSONValue],
    transport: BLETransport,
    expectedResult: JSONValue
) throws {
    guard let path else { return }

    var lines: [String] = []
    lines.append("{")
    lines.append("  \"name\": \"\(JSONValue.escape(name))\",")
    lines.append("  \"operation\": \"\(JSONValue.escape(operation))\",")
    lines.append("  \"input\": {")
    let inputEntries = input.map { (k, v) in "    \"\(JSONValue.escape(k))\": \(v.jsonEncoded)" }
    lines.append(inputEntries.joined(separator: ",\n"))
    lines.append("  },")
    lines.append("  \"expected_exchange_sequence\": [")
    var exchangeLines: [String] = []
    for record in transport.capturedRecords {
        exchangeLines.append("    {\"direction\": \"send\", \"apdu_hex\": \"\(record.send.hexEncodedString())\"}")
        let swHex = String(format: "0x%04X", record.sw)
        exchangeLines.append(
            "    {\"direction\": \"recv\", \"status_word\": \"\(swHex)\", \"data_hex\": \"\(record.recv.hexEncodedString())\"}"
        )
    }
    lines.append(exchangeLines.joined(separator: ",\n"))
    lines.append("  ],")
    lines.append("  \"expected_result\": \(expectedResult.jsonEncoded)")
    lines.append("}")

    let json = lines.joined(separator: "\n") + "\n"
    try json.write(toFile: path, atomically: true, encoding: .utf8)
    FileHandle.standardError.write("[capture] wrote \(transport.capturedRecords.count) exchange(s) → \(path)\n".data(using: .utf8)!)
}

// `fileprivate` so it doesn't conflict with BLETransport.swift's
// own private copy (Swift scoping resolves them independently).
extension Data {
    fileprivate func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
