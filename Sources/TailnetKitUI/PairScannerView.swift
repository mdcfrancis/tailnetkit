#if os(iOS)

    import SwiftUI
    import TailnetKit
    import VisionKit

    /// Camera view that scans a QR and hands back its raw string.
    ///
    /// Most callers want `PairingScannerSheet` instead, which decodes and
    /// validates the payload; this is the bare scanner for anything else.
    public struct PairScannerView: UIViewControllerRepresentable {

        private let onPayload: (String) -> Void

        public init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        /// False on the simulator and on devices without the hardware, so a
        /// caller can show an explanation instead of a black rectangle.
        public static var isAvailable: Bool {
            DataScannerViewController.isSupported
                && DataScannerViewController.isAvailable
        }

        public func makeUIViewController(context: Context) -> DataScannerViewController {
            let scanner = DataScannerViewController(
                recognizedDataTypes: [.barcode(symbologies: [.qr])],
                qualityLevel: .balanced,
                isHighlightingEnabled: true)
            scanner.delegate = context.coordinator
            try? scanner.startScanning()
            return scanner
        }

        public func updateUIViewController(
            _ controller: DataScannerViewController, context: Context
        ) {}

        public func makeCoordinator() -> Coordinator {
            Coordinator(onPayload: onPayload)
        }

        public final class Coordinator: NSObject, DataScannerViewControllerDelegate {
            private let onPayload: (String) -> Void
            /// The scanner keeps firing while a code is in frame; pairing
            /// must happen once.
            private var delivered = false

            init(onPayload: @escaping (String) -> Void) {
                self.onPayload = onPayload
            }

            public func dataScanner(
                _ scanner: DataScannerViewController,
                didAdd added: [RecognizedItem],
                allItems: [RecognizedItem]
            ) {
                guard !delivered else { return }
                for item in added {
                    if case .barcode(let barcode) = item,
                        let payload = barcode.payloadStringValue
                    {
                        delivered = true
                        scanner.stopScanning()
                        onPayload(payload)
                        return
                    }
                }
            }
        }
    }

    /// A ready-made scanning sheet: camera, cancel button, and payload
    /// validation. Only well-formed payloads reach `onScan`, so a stray QR
    /// from another app is ignored rather than half-applied.
    public struct PairingScannerSheet<Extra: Codable & Sendable>: View {

        @Environment(\.dismiss) private var dismiss
        private let title: String
        private let unavailableMessage: String
        private let onScan: (PairingPayload<Extra>) -> Void

        public init(
            title: String = "Scan the pairing QR",
            unavailableMessage: String =
                "This device can't scan QR codes. Set the server up manually "
                + "in Settings instead.",
            onScan: @escaping (PairingPayload<Extra>) -> Void
        ) {
            self.title = title
            self.unavailableMessage = unavailableMessage
            self.onScan = onScan
        }

        public var body: some View {
            NavigationStack {
                Group {
                    if PairScannerView.isAvailable {
                        PairScannerView { string in
                            guard let payload = PairingPayload<Extra>.decode(string)
                            else { return }
                            dismiss()
                            onScan(payload)
                        }
                        .ignoresSafeArea()
                    } else {
                        ContentUnavailableView(
                            "Camera unavailable",
                            systemImage: "camera.fill",
                            description: Text(unavailableMessage))
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

#endif
