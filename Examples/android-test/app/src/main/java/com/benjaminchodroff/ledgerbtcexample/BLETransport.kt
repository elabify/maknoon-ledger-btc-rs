// BLETransport: Android CoreBluetooth equivalent for the Ledger
// Nano X. Mechanical port of macOS/iOS BLETransport.swift.
//
// Caller must hold BLUETOOTH_CONNECT + BLUETOOTH_SCAN permissions
// (Android 12+) before calling `connect()`. The app must also
// pair the Ledger Nano X via Settings > Bluetooth FIRST; this
// transport reuses the OS-level pairing rather than initiating
// its own.
//
// UNTESTED on real hardware (Week 4 part B was implemented
// without an Android device available). Mechanical correctness
// only: shapes the API exactly the same way iOS/macOS does, with
// identical 153-byte MTU cap, 5-byte BLE framing, and 400/500ms
// Battery Service heartbeat. Real-device validation is pending.

package com.benjaminchodroff.ledgerbtcexample

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import uniffi.ledger_btc_core.ExchangeResponse
import uniffi.ledger_btc_core.Transport
import uniffi.ledger_btc_core.TransportException
import java.util.UUID

private const val TAG = "LedgerBLE"
private val LEDGER_SERVICE_UUID = UUID.fromString("13d63400-2c97-0004-0000-4c6564676572")
private val LEDGER_WRITE_UUID   = UUID.fromString("13d63400-2c97-0004-0002-4c6564676572")
private val LEDGER_NOTIFY_UUID  = UUID.fromString("13d63400-2c97-0004-0001-4c6564676572")
private val BATTERY_SERVICE_UUID = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
private val BATTERY_LEVEL_UUID   = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")
private val CCC_DESCRIPTOR_UUID  = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

private const val BLE_APDU_TAG: Byte = 0x05
private const val SAFE_MTU: Int = 153  // Verified Ledger Nano X cap.

/**
 * Production BLE transport. Untested without hardware; use
 * [MockTransport] for emulator UI work.
 *
 * Lifecycle: `connect()` → any number of `exchange(apdu)` calls →
 * the transport stays connected until process death or device
 * disconnect.
 */
@OptIn(kotlin.ExperimentalUnsignedTypes::class)
@SuppressLint("MissingPermission")  // caller is responsible for runtime perms
class BLETransport(
    private val context: Context,
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.IO),
    private val scanTimeoutMs: Long = 25_000,
    private val connectTimeoutMs: Long = 15_000,
    private val apduTimeoutMs: Long = 60_000,
) : Transport {

    private val bluetoothManager: BluetoothManager =
        context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager
    private val bluetoothAdapter: BluetoothAdapter? = bluetoothManager.adapter

    private var gatt: BluetoothGatt? = null
    private var writeChar: BluetoothGattCharacteristic? = null
    private var notifyChar: BluetoothGattCharacteristic? = null
    private var batteryLevelChar: BluetoothGattCharacteristic? = null

    private var pendingAPDU: PendingAPDU? = null
    private class PendingAPDU(
        var totalLength: Int = -1,
        var buffer: ByteArray = ByteArray(0),
        val result: CompletableDeferred<ByteArray> = CompletableDeferred(),
    )

    private var heartbeatJob: Job? = null

    suspend fun connect() {
        if (bluetoothAdapter?.isEnabled != true) {
            throw TransportException.Io(reason = "Bluetooth is off or unsupported")
        }
        if (gatt != null) return

        val device = scanForLedger()
            ?: throw TransportException.Io(reason = "Ledger BLE device not found within ${scanTimeoutMs}ms")
        val connected = connectGatt(device)
        if (!connected) {
            throw TransportException.Disconnected(reason = "GATT connect failed")
        }
        discoverServices()
        if (writeChar == null || notifyChar == null) {
            throw TransportException.Io(reason = "Ledger APDU characteristics not found")
        }
    }

    fun disconnect() {
        heartbeatJob?.cancel()
        heartbeatJob = null
        gatt?.disconnect()
        gatt?.close()
        gatt = null
        writeChar = null
        notifyChar = null
        batteryLevelChar = null
    }

    // MARK: -- Transport

    override suspend fun exchange(apdu: ByteArray): ExchangeResponse {
        val writeCh = writeChar ?: throw TransportException.Disconnected(reason = "not connected")
        val gattRef = gatt ?: throw TransportException.Disconnected(reason = "not connected")
        // Fail any stale pending APDU before installing a new one.
        pendingAPDU?.result?.completeExceptionally(
            TransportException.Io(reason = "previous exchange abandoned")
        )
        pendingAPDU = null

        val pending = PendingAPDU()
        pendingAPDU = pending

        // Keep-alive heartbeat on the Battery Service. 400ms initial
        // delay so fast back-to-back rounds skip it; 500ms loop for
        // the long user-confirmation window. Matches verified-
        // stable iOS/macOS values.
        val battery = batteryLevelChar
        heartbeatJob = scope.launch {
            try {
                delay(400)
                while (true) {
                    val ch = battery ?: break
                    gattRef.readCharacteristic(ch)
                    delay(500)
                }
            } catch (_: Throwable) { /* cancellation */ }
        }

        // Send chunked APDU packets.
        val negotiatedMtu = SAFE_MTU  // we don't request MTU upgrade; 153 is the safe cap regardless
        val packets = framedPackets(apdu, negotiatedMtu)
        for (p in packets) {
            writeCh.value = p
            val ok = gattRef.writeCharacteristic(writeCh)
            if (!ok) {
                heartbeatJob?.cancel()
                throw TransportException.Io(reason = "writeCharacteristic returned false")
            }
        }

        val raw = withTimeoutOrNull(apduTimeoutMs) { pending.result.await() }
        heartbeatJob?.cancel()
        heartbeatJob = null
        if (raw == null) {
            pendingAPDU = null
            throw TransportException.Timeout(reason = "APDU response after ${apduTimeoutMs}ms")
        }
        if (raw.size < 2) {
            throw TransportException.Io(reason = "APDU response too short (${raw.size} bytes)")
        }
        val sw = (raw[raw.size - 2].toInt().and(0xff) shl 8) or raw[raw.size - 1].toInt().and(0xff)
        val data = raw.copyOfRange(0, raw.size - 2)
        return ExchangeResponse(statusWord = sw.toUShort(), data = data)
    }

    // MARK: -- internals

    private suspend fun scanForLedger(): BluetoothDevice? {
        val scanner = bluetoothAdapter?.bluetoothLeScanner
            ?: return null
        val found = CompletableDeferred<BluetoothDevice>()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                if (!found.isCompleted) found.complete(result.device)
            }
            override fun onScanFailed(errorCode: Int) {
                if (!found.isCompleted) {
                    found.completeExceptionally(
                        TransportException.Io(reason = "BLE scan failed (error $errorCode)")
                    )
                }
            }
        }
        val filters = listOf(
            ScanFilter.Builder().setServiceUuid(android.os.ParcelUuid(LEDGER_SERVICE_UUID)).build()
        )
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        scanner.startScan(filters, settings, callback)
        val device = try {
            withTimeoutOrNull(scanTimeoutMs) { found.await() }
        } finally {
            scanner.stopScan(callback)
        }
        return device
    }

    private suspend fun connectGatt(device: BluetoothDevice): Boolean {
        val ready = CompletableDeferred<Boolean>()
        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    if (!ready.isCompleted) ready.complete(true)
                } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                    handleDisconnect(reason = "STATE_DISCONNECTED status=$status")
                    if (!ready.isCompleted) ready.complete(false)
                }
            }
            override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
                onServicesDiscoveredImpl(g, status)
            }
            override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                onCharacteristicChangedImpl(characteristic)
            }
            override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
                // No-op: we don't gate sequential writes on this; the
                // device tolerates back-to-back writeCharacteristic
                // calls so long as we don't exceed MTU per write.
            }
            override fun onCharacteristicRead(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
                // Battery reads are heartbeat-only; nothing to do.
            }
        }
        val newGatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, callback)
        }
        this.gatt = newGatt
        val connected = withTimeoutOrNull(connectTimeoutMs) { ready.await() } ?: false
        return connected
    }

    private suspend fun discoverServices() {
        val g = gatt ?: return
        val discovered = CompletableDeferred<Boolean>()
        servicesDiscoveryGate = discovered
        g.discoverServices()
        withTimeoutOrNull(connectTimeoutMs) { discovered.await() }
        servicesDiscoveryGate = null
    }

    private var servicesDiscoveryGate: CompletableDeferred<Boolean>? = null

    private fun onServicesDiscoveredImpl(g: BluetoothGatt, status: Int) {
        if (status != BluetoothGatt.GATT_SUCCESS) {
            servicesDiscoveryGate?.complete(false)
            return
        }
        val ledgerSvc: BluetoothGattService? = g.getService(LEDGER_SERVICE_UUID)
        val batterySvc: BluetoothGattService? = g.getService(BATTERY_SERVICE_UUID)
        writeChar = ledgerSvc?.getCharacteristic(LEDGER_WRITE_UUID)
        notifyChar = ledgerSvc?.getCharacteristic(LEDGER_NOTIFY_UUID)
        batteryLevelChar = batterySvc?.getCharacteristic(BATTERY_LEVEL_UUID)
        val nc = notifyChar
        if (nc != null) {
            g.setCharacteristicNotification(nc, true)
            // Required to actually enable notifications on most BLE
            // stacks: write 0x01 0x00 to the CCC descriptor.
            val ccc = nc.getDescriptor(CCC_DESCRIPTOR_UUID)
            if (ccc != null) {
                ccc.value = BluetoothGattDescriptorEnable
                g.writeDescriptor(ccc)
            }
        }
        servicesDiscoveryGate?.complete(true)
    }

    private fun onCharacteristicChangedImpl(characteristic: BluetoothGattCharacteristic) {
        // Filter: only the Ledger notify characteristic carries
        // APDU response packets. Battery reads come through
        // onCharacteristicRead and we ignore them.
        if (characteristic.uuid != LEDGER_NOTIFY_UUID) return
        val data = characteristic.value ?: return
        val pending = pendingAPDU ?: return
        if (data.size < 3 || data[0] != BLE_APDU_TAG) return
        val packetIdx = (data[1].toInt().and(0xff) shl 8) or data[2].toInt().and(0xff)
        var offset = 3
        if (packetIdx == 0) {
            if (data.size < 5) return
            pending.totalLength = (data[3].toInt().and(0xff) shl 8) or data[4].toInt().and(0xff)
            offset = 5
        }
        pending.buffer += data.copyOfRange(offset, data.size)
        if (pending.totalLength > 0 && pending.buffer.size >= pending.totalLength) {
            pending.result.complete(pending.buffer.copyOf(pending.totalLength))
            pendingAPDU = null
        }
    }

    private fun handleDisconnect(reason: String) {
        val err = TransportException.Disconnected(reason = reason)
        pendingAPDU?.result?.completeExceptionally(err)
        pendingAPDU = null
        heartbeatJob?.cancel()
        heartbeatJob = null
    }
}

// CCC descriptor bytes that enable BLE notifications on the
// characteristic it belongs to. Same value across all Android
// versions; defined as a constant to keep the discovery path tidy.
private val BluetoothGattDescriptorEnable = byteArrayOf(0x01, 0x00)

private fun framedPackets(apdu: ByteArray, mtu: Int): List<ByteArray> {
    val out = ArrayList<ByteArray>()
    var remaining = apdu
    var idx = 0
    while (remaining.isNotEmpty()) {
        val header = ArrayList<Byte>()
        header.add(BLE_APDU_TAG)
        header.add(((idx shr 8) and 0xff).toByte())
        header.add((idx and 0xff).toByte())
        if (idx == 0) {
            header.add(((apdu.size shr 8) and 0xff).toByte())
            header.add((apdu.size and 0xff).toByte())
        }
        var take = mtu - header.size
        if (take > remaining.size) take = remaining.size
        val chunk = ByteArray(header.size + take)
        for ((i, b) in header.withIndex()) chunk[i] = b
        System.arraycopy(remaining, 0, chunk, header.size, take)
        out.add(chunk)
        remaining = remaining.copyOfRange(take, remaining.size)
        idx += 1
    }
    return out
}
