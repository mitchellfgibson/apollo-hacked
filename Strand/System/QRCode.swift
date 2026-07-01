import Foundation
import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins

/// Generates a crisp QR code image for a string (e.g. a crypto address) so people can scan straight
/// from their wallet — the lowest-friction way to donate. Cross-platform: returns a SwiftUI `Image`
/// built from the shared CoreImage `CGImage`, so no AppKit/UIKit at the call site.
enum QRCode {
    private static let context = CIContext()

    /// A ready-to-render SwiftUI image, or `nil` if generation failed.
    static func image(for string: String, scale: CGFloat = 12) -> Image? {
        guard let cg = cgImage(for: string, scale: scale) else { return nil }
        return Image(decorative: cg, scale: 1, orientation: .up)
    }

    private static func cgImage(for string: String, scale: CGFloat) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
