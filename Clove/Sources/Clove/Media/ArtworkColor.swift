import AppKit
import SwiftUI

enum ArtworkColor {
    static func accent(for image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return .white
        }

        var buffer = [UInt8](repeating: 0, count: 4)
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat

        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }

            context.interpolationQuality = .medium
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        r = CGFloat(buffer[0]) / 255.0
        g = CGFloat(buffer[1]) / 255.0
        b = CGFloat(buffer[2]) / 255.0

        let nsColor = NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        var h: CGFloat = 0
        var s: CGFloat = 0
        var br: CGFloat = 0
        nsColor.getHue(&h, saturation: &s, brightness: &br, alpha: nil)

        let boostedS = min(1.0, s * 1.3)
        let boostedB = max(br, 0.75)

        return Color(hue: h, saturation: boostedS, brightness: boostedB)
    }
}
