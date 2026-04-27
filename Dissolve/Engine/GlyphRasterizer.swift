import AppKit
import CoreGraphics

struct GlyphPixel {
    let x: Float
    let y: Float
}

enum GlyphRasterizer {
    static func pixels(
        for string: String,
        rect: CGRect,
        font: NSFont,
        color: NSColor,
        scale: CGFloat = 0.5,
        alphaThreshold: UInt8 = 64
    ) -> [GlyphPixel] {
        guard !string.isEmpty, rect.width > 0, rect.height > 0 else { return [] }

        let width = max(1, Int(ceil(rect.width * scale)))
        let height = max(1, Int(ceil(rect.height * scale)))
        let bytesPerRow = width * 4
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }

        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)

        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        (string as NSString).draw(at: .zero, withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()

        guard let data = ctx.data else { return [] }
        let ptr = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var out: [GlyphPixel] = []
        out.reserveCapacity(width * height / 4)
        let inv = Float(1.0 / scale)
        let ox = Float(rect.origin.x)
        let oy = Float(rect.origin.y)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                if ptr[row + x * 4 + 3] > alphaThreshold {
                    out.append(GlyphPixel(x: ox + Float(x) * inv, y: oy + Float(y) * inv))
                }
            }
        }
        return out
    }
}
