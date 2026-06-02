package com.benjaminchodroff.ledgerbtcexample

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.launch
import uniffi.ledger_btc_core.LedgerBitcoinClient
import uniffi.ledger_btc_core.WalletPolicy

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    LedgerScreen()
                }
            }
        }
    }
}

@OptIn(kotlin.ExperimentalUnsignedTypes::class)
class LedgerViewModel : ViewModel() {
    // Mock transport in this example; replaced with BLETransport
    // on a real device.
    private val transport = MockTransport()
    private val client = LedgerBitcoinClient(transport)

    var status by mutableStateOf("Idle. Tap Connect to read fingerprint + xpub.")
        private set
    var isBusy by mutableStateOf(false)
        private set
    var fingerprint by mutableStateOf<String?>(null)
        private set
    var xpub by mutableStateOf<String?>(null)
        private set

    fun connect() = viewModelScope.launch {
        run("Reading fingerprint + xpub") {
            val fp = client.getMasterFingerprint()
            fingerprint = fp.joinToString("") { "%02x".format(it.toInt().and(0xff)) }
            xpub = client.getExtendedPubkey(path = "m/84'/0'/0'", display = false)
        }
    }

    private suspend fun run(label: String, op: suspend () -> Unit) {
        isBusy = true
        status = label
        try {
            op()
            status = "Done."
        } catch (t: Throwable) {
            status = "Failed: ${t.message ?: t::class.simpleName}"
        } finally {
            isBusy = false
        }
    }
}

@Composable
fun LedgerScreen(vm: LedgerViewModel = viewModel()) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
            .verticalScroll(rememberScrollState()),
        verticalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Text("Ledger BTC Example (Android)", style = MaterialTheme.typography.headlineSmall)
        Text(
            "Running with MockTransport. A real device requires the " +
            "BLETransport class (week 4 part B) and a physical Android phone.",
            style = MaterialTheme.typography.bodySmall
        )

        Card {
            Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Status", style = MaterialTheme.typography.titleSmall)
                Text(vm.status, style = MaterialTheme.typography.bodySmall)
                if (vm.isBusy) {
                    LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                }
            }
        }

        Button(onClick = { vm.connect() }, enabled = !vm.isBusy) {
            Text("Connect (mock) + read fingerprint / xpub")
        }

        vm.fingerprint?.let {
            Card {
                Column(Modifier.padding(12.dp)) {
                    Text("Fingerprint", style = MaterialTheme.typography.titleSmall)
                    Text(it, fontFamily = FontFamily.Monospace)
                }
            }
        }
        vm.xpub?.let {
            Card {
                Column(Modifier.padding(12.dp)) {
                    Text("xpub (m/84'/0'/0')", style = MaterialTheme.typography.titleSmall)
                    Text(it, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                }
            }
        }
    }
}
