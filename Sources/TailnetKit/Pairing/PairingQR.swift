import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Renders a pairing payload to a QR bitmap.
///
/// Returns a `CGImage` rather than an `NSImage`/`UIImage` so the same code
/// serves both platforms; `TailnetKitUI` does the per-platform wrapping.
public enum PairingQR {

    /// - Parameters:
    ///   - scale: integer pixel scale. The generator emits one pixel per
    ///     module, which is unreadably small on screen; scaling by an integer
    ///     and drawing without interpolation keeps the edges hard, which is
    ///     what cameras want.
    ///   - correctionLevel: "L", "M", "Q" or "H". "M" is the useful default —
    ///     a pairing payload is dense enough that "Q"/"H" push the module
    ///     count up faster than the added redundancy helps.
    public static func image(
        for string: String,
        scale: CGFloat = 12,
        correctionLevel: String = "M"
    ) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    /// Convenience for the common path: encode the payload, then render it.
    public static func image<Extra>(
        for payload: PairingPayload<Extra>,
        scale: CGFloat = 12,
        correctionLevel: String = "M"
    ) -> CGImage? {
        guard let encoded = try? payload.encoded() else { return nil }
        return image(for: encoded, scale: scale, correctionLevel: correctionLevel)
    }
}
