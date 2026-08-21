import CoreImage
import CoreImage.CIFilterBuiltins
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Genera un código QR a partir de un texto (sin dependencias externas, vía CoreImage).
enum QRCode {
    static func image(from string: String, scale: CGFloat = 12) -> PlatformImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(out, from: out.extent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cg, size: NSSize(width: out.extent.width, height: out.extent.height))
        #else
        return UIImage(cgImage: cg)
        #endif
    }
}
