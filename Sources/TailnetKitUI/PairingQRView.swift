#if os(macOS)

    import AppKit
    import SwiftUI
    import TailnetKit

    /// The server-side half of pairing: a QR carrying everything the client
    /// needs, shown on the Mac for a phone to scan.
    ///
    /// Pass `nil` for `payload` while the node has no address yet — the view
    /// explains the wait rather than rendering an unusable code.
    public struct PairingQRView<Extra: Codable & Sendable>: View {

        private let payload: PairingPayload<Extra>?
        private let caption: String?
        private let instruction: String?
        private let unavailableTitle: String
        private let unavailableMessage: String

        /// - Parameters:
        ///   - caption: overrides the default explanation of what the code
        ///     carries, which already adapts to whether an auth key is
        ///     included.
        ///   - instruction: the "where to scan this" line, e.g.
        ///     `"Acme app → Settings → Scan Pairing QR"`.
        public init(
            payload: PairingPayload<Extra>?,
            caption: String? = nil,
            instruction: String? = nil,
            unavailableTitle: String = "Tailnet not joined",
            unavailableMessage: String =
                "Enable the tailnet in Settings and complete the sign-in; "
                + "the QR appears once the node has an address."
        ) {
            self.payload = payload
            self.caption = caption
            self.instruction = instruction
            self.unavailableTitle = unavailableTitle
            self.unavailableMessage = unavailableMessage
        }

        /// Whether the code is self-sufficient changes what the user has to
        /// do next, so it is worth saying plainly.
        private var defaultCaption: String {
            payload?.tailnetAuthKey == nil
                ? "Carries the server address and API token. The device still "
                    + "needs tailnet access of its own — either it signs in, or "
                    + "you set an auth key first to make pairing fully automatic."
                : "Carries the server address, API token, and the tailnet auth "
                    + "key — scanning joins and connects in one step."
        }

        public var body: some View {
            VStack(spacing: 16) {
                if let payload, let image = PairingQR.image(for: payload) {
                    Image(
                        nsImage: NSImage(
                            cgImage: image,
                            size: NSSize(width: image.width, height: image.height))
                    )
                    // The generator emits one pixel per module; smoothing it
                    // is what makes a code hard to scan.
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .accessibilityLabel("Pairing QR code")

                    Text(caption ?? defaultCaption)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 300)

                    if let instruction {
                        Text(instruction)
                            .font(.callout.weight(.medium))
                    }
                } else {
                    ContentUnavailableView(
                        unavailableTitle,
                        systemImage: "qrcode",
                        description: Text(unavailableMessage))
                }
            }
            .padding(24)
            .frame(minWidth: 360, minHeight: 420)
        }
    }

#endif
