#if os(iOS)

    import SwiftUI
    import TailnetKit

    /// First-run screen for an unpaired install: one job, one button.
    ///
    /// Gate an app's real UI on `connection.isConfigured` and show this
    /// otherwise — a fresh install then opens straight into pairing.
    public struct PairingWelcomeView<Extra: Codable & Sendable>: View {

        private let connection: TailnetConnection
        private let title: String
        private let message: String
        private let onManualSetup: (() -> Void)?
        private let onPaired: ((Extra?) -> Void)?

        /// - Parameters:
        ///   - message: where to find the code, e.g. "On your Mac, open
        ///     Acme → Settings → Pair device, then scan the QR code."
        ///   - onManualSetup: when set, offers an escape hatch for users who
        ///     cannot scan.
        ///   - onPaired: receives the app-specific extras from the scanned
        ///     payload; the transport settings are already applied.
        public init(
            connection: TailnetConnection,
            title: String = "Pair this device",
            message: String,
            onManualSetup: (() -> Void)? = nil,
            onPaired: ((Extra?) -> Void)? = nil
        ) {
            self.connection = connection
            self.title = title
            self.message = message
            self.onManualSetup = onManualSetup
            self.onPaired = onPaired
        }

        @State private var showingScanner = false

        public var body: some View {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 72))
                    .foregroundStyle(.tint)

                Text(title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)

                Button {
                    showingScanner = true
                } label: {
                    Label("Scan Pairing QR", systemImage: "camera.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 32)

                // Pairing brings a node up and signs in; without progress
                // this button looks like it did nothing for several seconds.
                if case .starting(let detail) = connection.status {
                    HStack {
                        ProgressView()
                        Text(detail)
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } else if case .failed(let error) = connection.status {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                if let onManualSetup {
                    Button("Set up manually", action: onManualSetup)
                        .font(.footnote)
                        .padding(.bottom, 16)
                }
            }
            .sheet(isPresented: $showingScanner) {
                PairingScannerSheet<Extra> { payload in
                    Task {
                        await connection.applyPairing(payload)
                        onPaired?(payload.app)
                    }
                }
            }
        }
    }

#endif
