// CoreBluetooth implementation of ledger-btc-core's Transport
// protocol for the Ledger Nano X on macOS.
//
// Owned by this CLI example, not by the SDK. Production iOS / Mac
// hosts would write their own version; the protocol shape is what
// matters. This is the reference implementation for what each
// platform layer needs to do.

import CoreBluetooth
import Foundation

private let ledgerServiceUUID = CBUUID(string: "13d63400-2c97-0004-0000-4c6564676572")
private let ledgerWriteUUID   = CBUUID(string: "13d63400-2c97-0004-0002-4c6564676572")
private let ledgerNotifyUUID  = CBUUID(string: "13d63400-2c97-0004-0001-4c6564676572")

// Standard Battery Service for the keep-alive heartbeat.
private let batteryServiceUUID = CBUUID(string: "180F")
private let batteryLevelUUID   = CBUUID(string: "2A19")

// Per the Ledger BLE protocol doc: tag(0x05) || idx_be(2) ||
// [first packet only: total_len_be(2)] || chunk.
private let bleApduTag: UInt8 = 0x05

// Verified-stable safe MTU on Nano X. macOS sometimes reports
// 512 via maximumWriteValueLength but the device actually caps
// around 153.
private let safeMTU = 153

final class BLETransport: NSObject, @unchecked Sendable, Transport {
    private let verbose: Bool

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var batteryLevelChar: CBCharacteristic?

    // One-shot continuations resolved by the CB delegates.
    private var poweredOnCont: CheckedContinuation<Void, Error>?
    private var connectedCont: CheckedContinuation<Void, Error>?
    private var discoveredCont: CheckedContinuation<Void, Error>?

    // The exchange()-in-flight reassembly state.
    private var pendingAPDU: PendingAPDU?
    private struct PendingAPDU {
        var totalLength: Int
        var buffer: Data
        var continuation: CheckedContinuation<Data, Error>?
    }

    init(verbose: Bool = false) {
        self.verbose = verbose
        super.init()
    }

    func connect() async throws {
        if let p = peripheral, p.state == .connected, writeChar != nil, notifyChar != nil {
            return
        }
        central?.stopScan()
        if let p = peripheral, let c = central {
            c.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        batteryLevelChar = nil

        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            if let central, central.state == .poweredOn {
                cont.resume()
            } else {
                self.poweredOnCont = cont
            }
        }
        log("scan: looking for Ledger service")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.connectedCont = cont
            self.central?.scanForPeripherals(withServices: [ledgerServiceUUID], options: nil)
        }
        log("connected, discovering services")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.discoveredCont = cont
            self.peripheral?.discoverServices([ledgerServiceUUID, batteryServiceUUID])
        }
        log("ready: write=\(writeChar?.uuid.uuidString ?? "?") notify=\(notifyChar?.uuid.uuidString ?? "?")")
    }

    // MARK: -- Transport protocol

    func exchange(apdu: Data) async throws -> ExchangeResponse {
        guard let writeChar, let peripheral, peripheral.state == .connected else {
            throw TransportError.Disconnected(reason: "BLE not connected")
        }
        if let stale = pendingAPDU?.continuation {
            stale.resume(throwing: TransportError.Io(reason: "previous exchange abandoned"))
        }
        pendingAPDU = nil

        log(">>> APDU (\(apdu.count) B): \(apdu.hexEncodedString())")

        // Keep-alive heartbeat: 400ms initial delay, then 500ms
        // intervals. Verified stable across the 200+ round
        // SIGN_PSBT flow on macOS in the research-stage Swift port.
        let heartbeat = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                while !Task.isCancelled {
                    guard let self,
                          self.peripheral?.state == .connected,
                          let batChar = self.batteryLevelChar else { break }
                    self.peripheral?.readValue(for: batChar)
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            } catch {
                // cancellation, parent op completed
            }
        }
        defer { heartbeat.cancel() }

        let raw = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.pendingAPDU = PendingAPDU(totalLength: -1, buffer: Data(), continuation: cont)
            let reported = peripheral.maximumWriteValueLength(for: .withResponse) - 3
            let mtu = max(20, min(safeMTU, reported))
            for packet in framedPackets(apdu: apdu, mtu: mtu) {
                peripheral.writeValue(packet, for: writeChar, type: .withResponse)
            }
        }
        guard raw.count >= 2 else {
            throw TransportError.Io(reason: "APDU response too short (\(raw.count) bytes)")
        }
        let sw = (UInt16(raw[raw.count - 2]) << 8) | UInt16(raw[raw.count - 1])
        let data = Data(raw.prefix(raw.count - 2))
        log("<<< sw=0x\(String(format: "%04X", sw)) data=\(data.count) B")
        return ExchangeResponse(statusWord: sw, data: data)
    }

    private func log(_ s: String) {
        guard verbose else { return }
        FileHandle.standardError.write("[\(ts())] \(s)\n".data(using: .utf8)!)
    }

    private func ts() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: Date())
    }
}

// MARK: -- BLE framing helpers

private func framedPackets(apdu: Data, mtu: Int) -> [Data] {
    var packets: [Data] = []
    var remaining = apdu
    var idx: UInt16 = 0
    while !remaining.isEmpty {
        var header = Data()
        header.append(bleApduTag)
        header.append(UInt8(idx >> 8))
        header.append(UInt8(idx & 0xff))
        if idx == 0 {
            header.append(UInt8(apdu.count >> 8))
            header.append(UInt8(apdu.count & 0xff))
        }
        var take = mtu - header.count
        if take > remaining.count { take = remaining.count }
        var pkt = header
        pkt.append(remaining.prefix(take))
        packets.append(pkt)
        remaining = remaining.dropFirst(take)
        idx &+= 1
    }
    return packets
}

extension Data {
    fileprivate func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: -- CB delegates

extension BLETransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            poweredOnCont?.resume()
            poweredOnCont = nil
        case .unauthorized:
            poweredOnCont?.resume(throwing: TransportError.Io(
                reason: "Bluetooth permission denied. Grant access in System Settings."
            ))
            poweredOnCont = nil
        case .poweredOff:
            poweredOnCont?.resume(throwing: TransportError.Io(
                reason: "Bluetooth is off. Enable Bluetooth and retry."
            ))
            poweredOnCont = nil
        case .unsupported:
            poweredOnCont?.resume(throwing: TransportError.Io(
                reason: "This Mac does not support Bluetooth LE."
            ))
            poweredOnCont = nil
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        log("discovered \(peripheral.identifier.uuidString) rssi=\(RSSI)")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedCont?.resume()
        connectedCont = nil
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        let reason = error?.localizedDescription ?? "unknown"
        connectedCont?.resume(throwing: TransportError.Disconnected(
            reason: "connect failed: \(reason)"
        ))
        connectedCont = nil
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        let reason = error?.localizedDescription ?? "device disconnected"
        let err = TransportError.Disconnected(reason: reason)
        pendingAPDU?.continuation?.resume(throwing: err)
        pendingAPDU = nil
        connectedCont?.resume(throwing: err)
        connectedCont = nil
        discoveredCont?.resume(throwing: err)
        discoveredCont = nil
        writeChar = nil
        notifyChar = nil
        batteryLevelChar = nil
        self.peripheral = nil
    }
}

extension BLETransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            discoveredCont?.resume(throwing: TransportError.Disconnected(
                reason: "service discovery failed: \(error.localizedDescription)"
            ))
            discoveredCont = nil
            return
        }
        for svc in peripheral.services ?? [] {
            if svc.uuid == ledgerServiceUUID {
                peripheral.discoverCharacteristics([ledgerWriteUUID, ledgerNotifyUUID], for: svc)
            } else if svc.uuid == batteryServiceUUID {
                peripheral.discoverCharacteristics([batteryLevelUUID], for: svc)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        let chars = service.characteristics ?? []
        if service.uuid == batteryServiceUUID {
            batteryLevelChar = chars.first { $0.uuid == batteryLevelUUID }
            return
        }
        writeChar = chars.first { $0.uuid == ledgerWriteUUID }
        notifyChar = chars.first { $0.uuid == ledgerNotifyUUID }
        guard let notifyChar else {
            discoveredCont?.resume(throwing: TransportError.Io(
                reason: "Ledger notify characteristic missing"
            ))
            discoveredCont = nil
            return
        }
        peripheral.setNotifyValue(true, for: notifyChar)
        discoveredCont?.resume()
        discoveredCont = nil
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if characteristic.uuid == batteryLevelUUID { return }
        guard characteristic.uuid == ledgerNotifyUUID, let data = characteristic.value else { return }
        guard var pending = pendingAPDU else { return }
        pendingAPDU = nil
        guard data.count >= 3, data[0] == bleApduTag else {
            pendingAPDU = pending
            return
        }
        let packetIdx = (UInt16(data[1]) << 8) | UInt16(data[2])
        var offset = 3
        if packetIdx == 0 {
            guard data.count >= 5 else { pendingAPDU = pending; return }
            pending.totalLength = (Int(data[3]) << 8) | Int(data[4])
            offset = 5
        }
        pending.buffer.append(data.suffix(from: offset))
        if pending.totalLength > 0, pending.buffer.count >= pending.totalLength {
            let final = Data(pending.buffer.prefix(pending.totalLength))
            pending.continuation?.resume(returning: final)
            pending.continuation = nil
        } else {
            pendingAPDU = pending
        }
    }
}
