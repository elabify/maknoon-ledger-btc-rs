// Thin SwiftUI wrapper around VisionKit's DataScannerViewController
// for one-shot QR code scanning. iOS 17+ only (DataScanner needs a
// neural-engine iPhone, which every iOS-17-supported model has).

import SwiftUI
import VisionKit

/// Presents a fullscreen camera view that recognizes a single QR
/// code, hands its decoded string back via `onScanned`, and
/// dismisses itself. If the device doesn't support DataScanner or
/// camera access was denied, surfaces the reason via `onError`.
struct QRScannerView: UIViewControllerRepresentable {
    var onScanned: (String) -> Void
    var onError: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        do {
            try scanner.startScanning()
        } catch {
            onError("could not start camera: \(error.localizedDescription)")
        }
        return scanner
    }

    func updateUIViewController(_: DataScannerViewController, context _: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: QRScannerView
        private var handled = false

        init(parent: QRScannerView) {
            self.parent = parent
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd added: [RecognizedItem], allItems _: [RecognizedItem]) {
            guard !handled else { return }
            for item in added {
                if case let .barcode(barcode) = item,
                   let payload = barcode.payloadStringValue, !payload.isEmpty {
                    handled = true
                    scanner.stopScanning()
                    parent.onScanned(payload)
                    return
                }
            }
        }

        func dataScanner(_: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            parent.onError("scanner unavailable: \(error)")
        }
    }
}

/// Sheet-presented host that wraps the scanner and a Cancel button.
struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onScanned: (String) -> Void

    @State private var errorText: String?

    var body: some View {
        ZStack(alignment: .top) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                QRScannerView(
                    onScanned: { value in
                        onScanned(value)
                        dismiss()
                    },
                    onError: { msg in
                        errorText = msg
                    }
                )
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                VStack(spacing: 12) {
                    Spacer()
                    Text("QR scanner not available on this device.")
                        .foregroundColor(.white)
                    Text("Make sure camera permission is granted in Settings.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.thinMaterial, in: Capsule())
                }
                .padding()
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .padding(8)
                        .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundColor(.white)
                        .padding(.horizontal)
                }
                Spacer()
            }
        }
    }
}
