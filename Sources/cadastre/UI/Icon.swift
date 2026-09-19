import AppKit

/// The app icon, laid out by the same squarifier as the map itself.
///
/// Drawing something that merely resembles a treemap would have been quicker
/// and would drift the first time the algorithm changed. These are real packed
/// rectangles in the real palette.
enum AppIcon {
    /// Values chosen to give one dominant block and a readable tail, which is
    /// what a disk actually looks like.
    private static let weights: [Float] = [34, 19, 13, 9, 7, 5, 4, 3, 2.2, 1.8, 1.4, 1.1]
    private static let families: [Palette.Family] = [
        .image, .code, .data, .document, .video, .audio, .code, .data, .other, .document, .image, .video,
    ]

    static func image(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let inset = size * 0.055
        let card = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        let radius = size * 0.2

        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.086, alpha: 1).setFill()
        NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius).fill()

        let clip = NSBezierPath(roundedRect: card.insetBy(dx: size * 0.055, dy: size * 0.055),
                                xRadius: radius * 0.45, yRadius: radius * 0.45)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()

        let field = clip.bounds
        let packed = TreemapLayout.pack(weights, in: Rect(x: Float(field.minX), y: Float(field.minY),
                                                         width: Float(field.width),
                                                         height: Float(field.height)))
        let gap = max(size * 0.012, 0.5)
        for (index, rect) in packed.enumerated() {
            let colour = Palette.family(families[index % families.count], .dark)
            colour.nsColor.setFill()
            NSRect(x: CGFloat(rect.x), y: CGFloat(rect.y),
                   width: CGFloat(rect.width), height: CGFloat(rect.height))
                .insetBy(dx: gap, dy: gap)
                .fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return image
    }

    /// Write the .iconset directory `iconutil` expects.
    static func writeIconset(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                                      (256, 1), (256, 2), (512, 1), (512, 2)]
        for (points, scale) in variants {
            let pixels = points * scale
            let rendered = image(size: CGFloat(pixels))
            guard let tiff = rendered.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:])
            else { continue }
            let suffix = scale == 1 ? "" : "@2x"
            let name = "icon_\(points)x\(points)\(suffix).png"
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
    }
}
