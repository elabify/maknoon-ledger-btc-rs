// Single-screen iOS test app for ledger-btc-core. Exercises the
// same four operations as the macOS CLI:
//   - getMasterFingerprint
//   - getExtendedPubkey
//   - getWalletAddress (default BIP-84 policy)
//   - signPsbt
// against a real Ledger Nano X over BLE.

import SwiftUI

@MainActor
final class LedgerViewModel: ObservableObject {
    private let transport = BLETransport(verbose: false)
    private lazy var client = LedgerBitcoinClient(transport: transport)

    @Published var status: String = "Idle. Tap Connect to begin."
    @Published var isBusy: Bool = false

    // Cached device state populated by `connect()`.
    @Published var fingerprintHex: String?
    @Published var accountXpub: String?

    // User inputs.
    @Published var network: LedgerBitcoinNetwork = .mainnet
    @Published var account: UInt32 = 0
    @Published var addressIndex: UInt32 = 0
    @Published var unsignedPSBT: String = ""

    // Outputs.
    @Published var derivedAddress: String?
    @Published var signedPSBT: String?

    func connect() async {
        await run("Connecting + reading fingerprint and xpub") {
            try await self.transport.connect()
            let fp = try await self.client.getMasterFingerprint()
            self.fingerprintHex = fp.map { String(format: "%02x", $0) }.joined()
            let path = "m/84'/\(self.network.coinTypeString)'/\(self.account)'"
            self.accountXpub = try await self.client.getExtendedPubkey(
                path: path,
                display: false
            )
        }
    }

    func deriveAddress(display: Bool) async {
        guard let policy = makePolicy() else {
            status = "Connect first to populate fingerprint + xpub."
            return
        }
        await run(display ? "Confirm the address on your Ledger..."
                          : "Fetching address \(addressIndex)") {
            self.derivedAddress = try await self.client.getWalletAddress(
                policy: policy,
                change: 0,
                index: self.addressIndex,
                display: display
            )
        }
    }

    func sign() async {
        guard let policy = makePolicy() else {
            status = "Connect first to populate fingerprint + xpub."
            return
        }
        let trimmed = unsignedPSBT.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = "Paste a base64 PSBT first."
            return
        }
        await run("Confirm the transaction on your Ledger...") {
            self.signedPSBT = try await self.client.signPsbt(
                psbtBase64: trimmed,
                policy: policy
            )
        }
    }

    // MARK: -- helpers

    private func makePolicy() -> WalletPolicy? {
        guard let fp = fingerprintHex, let xpub = accountXpub else { return nil }
        let keyOrigin = "[\(fp)/84'/\(network.coinTypeString)'/\(account)']\(xpub)"
        return WalletPolicy(
            name: "",
            descriptorTemplate: "wpkh(@0/**)",
            keys: [keyOrigin],
            hmac: nil
        )
    }

    private func run(_ label: String, op: @escaping () async throws -> Void) async {
        isBusy = true
        status = label
        defer { isBusy = false }
        do {
            try await op()
            status = "Done."
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }
}

extension LedgerBitcoinNetwork {
    fileprivate var coinTypeString: String {
        switch self {
        case .mainnet: return "0"
        case .testnet: return "1"
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = LedgerViewModel()
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Text(vm.status)
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                    if vm.isBusy {
                        ProgressView()
                    }
                }

                Section("Configuration") {
                    Picker("LedgerBitcoinNetwork", selection: $vm.network) {
                        Text("Mainnet").tag(LedgerBitcoinNetwork.mainnet)
                        Text("Testnet").tag(LedgerBitcoinNetwork.testnet)
                    }
                    Stepper("Account: \(vm.account)", value: $vm.account, in: 0...10)
                }

                Section("Device") {
                    Button("Connect + load fingerprint / xpub") {
                        Task { await vm.connect() }
                    }
                    .disabled(vm.isBusy)

                    if let fp = vm.fingerprintHex {
                        LabeledContent("Fingerprint", value: fp)
                            .font(.system(.body, design: .monospaced))
                    }
                    if let xpub = vm.accountXpub {
                        VStack(alignment: .leading) {
                            Text("Account xpub").font(.caption).foregroundStyle(.secondary)
                            Text(xpub).font(.caption2.monospaced()).textSelection(.enabled)
                        }
                    }
                }

                Section("Address derivation") {
                    Stepper("Index: \(vm.addressIndex)", value: $vm.addressIndex, in: 0...50)
                    Button("Derive address (no on-device prompt)") {
                        Task { await vm.deriveAddress(display: false) }
                    }
                    .disabled(vm.isBusy || vm.fingerprintHex == nil)
                    Button("Derive address (confirm on device)") {
                        Task { await vm.deriveAddress(display: true) }
                    }
                    .disabled(vm.isBusy || vm.fingerprintHex == nil)
                    if let a = vm.derivedAddress {
                        Text(a).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }

                Section("Sign PSBT") {
                    Button {
                        showingScanner = true
                    } label: {
                        Label("Scan PSBT QR code", systemImage: "qrcode.viewfinder")
                    }
                    TextEditor(text: $vm.unsignedPSBT)
                        .font(.caption2.monospaced())
                        .frame(minHeight: 100)
                    Button("Sign on Ledger") {
                        Task { await vm.sign() }
                    }
                    .disabled(vm.isBusy || vm.fingerprintHex == nil
                              || vm.unsignedPSBT.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let signed = vm.signedPSBT {
                        VStack(alignment: .leading) {
                            Text("Signed PSBT base64").font(.caption).foregroundStyle(.secondary)
                            Text(signed).font(.caption2.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Ledger BTC Example")
            .sheet(isPresented: $showingScanner) {
                QRScannerSheet { value in
                    vm.unsignedPSBT = value
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
