import AppKit
import Metal

/// Render the map to a PNG without a window.
///
/// Written first to be able to *look* at the thing — a palette that validates
/// on paper says nothing about whether the picture reads — and kept because
/// exporting a map is worth having on its own, and because it turns the
/// renderer into something a script can check rather than only an eye.
@MainActor
enum TreemapSnapshot {
    enum Failure: Error, CustomStringConvertible {
        case noRenderer, noTexture, encodingFailed
        var description: String {
            switch self {
            case .noRenderer: return tr("Metal unavailable")
            case .noTexture: return tr("could not allocate the render target")
            case .encodingFailed: return tr("PNG encoding failed")
            }
        }
    }

    static func write(model: TreemapModel, colorMode: ColorMode, mode: Palette.Mode,
                      size: CGSize, scale: CGFloat = 2, to path: String) throws {
        guard let renderer = TreemapRenderer() else { throw Failure.noRenderer }
        // The command line bounds --size; this is for any other caller. A
        // canvas of zero height is a zero-sized texture, which Metal aborts on.
        guard size.width.isFinite, size.height.isFinite, size.width >= 64, size.height >= 64
        else { throw Failure.noTexture }

        let canvas = CGSize(width: size.width, height: size.height - 28)  // legend strip
        let rects = TreemapLayout.compute(model, root: 0,
                                          in: Rect(x: 0, y: 0,
                                                   width: Float(canvas.width),
                                                   height: Float(canvas.height)))
        let fills = rects.map { colour(for: $0, model: model, colorMode: colorMode, mode: mode) }
        renderer.upload(TreemapRenderer.instances(rects: rects, fills: fills, model: model))

        guard let texture = renderer.renderToTexture(
            viewport: canvas, pixelScale: scale,
            background: Palette.plane(mode), border: Palette.surface(mode))
        else { throw Failure.noTexture }

        let pixelWidth = Int(canvas.width * scale), pixelHeight = Int(canvas.height * scale)
        var pixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        pixels.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: pixelWidth * 4,
                             from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight), mipmapLevel: 0)
        }

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 32)
        else { throw Failure.noTexture }
        // Before the context is made, not after: the context takes its
        // coordinate space from the rep's size at creation, so setting it
        // afterwards leaves everything drawn into a quarter of the bitmap.
        rep.size = size
        guard let base = NSGraphicsContext(bitmapImageRep: rep) else { throw Failure.noTexture }

        // Flip once, then work in the same top-left coordinates the views use,
        // and tell AppKit so text lands the right way up.
        let cg = base.cgContext
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }

        Palette.plane(mode).nsColor.setFill()
        NSRect(origin: .zero, size: size).fill()

        // Metal returns BGRA; CoreGraphics is told that rather than swizzled.
        if let provider = CGDataProvider(data: Data(pixels) as CFData),
           let image = CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                               bitsPerPixel: 32, bytesPerRow: pixelWidth * 4,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
                                                        | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false,
                               intent: .defaultIntent) {
            cg.saveGState()
            cg.translateBy(x: 0, y: canvas.height)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(image, in: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
            cg.restoreGState()
        }

        TreemapLabelPass(model: model, rects: rects, fills: fills, mode: mode).draw()

        let legend = LegendView(frame: NSRect(x: 0, y: canvas.height,
                                              width: size.width, height: 28))
        legend.appearance = NSAppearance(named: mode == .dark ? .darkAqua : .aqua)
        legend.mode = colorMode
        legend.caption = colorMode.label
        legend.hasBaseline = model.hasBaseline
        cg.saveGState()
        cg.translateBy(x: 0, y: canvas.height)
        legend.draw(legend.bounds)
        cg.restoreGState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw Failure.encodingFailed
        }
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func colour(for entry: TreemapRect, model: TreemapModel,
                       colorMode: ColorMode, mode: Palette.Mode) -> RGBA {
        let node = Int(entry.node)
        let surface = Palette.surface(mode)
        if model.isDirectory[node] && !entry.isLeaf {
            return RGBA.mix(surface, Palette.primaryInk(mode), 0.05 + 0.02 * Float(min(entry.depth, 4)))
        }
        // Whole-disk extras keep the same look in every mode: they are
        // context for the map, not part of what it measures.
        switch model.kind[node] {
        case .free: return RGBA.mix(surface, Palette.mutedInk, mode == .light ? 0.12 : 0.22)
        case .volume: return RGBA.mix(Palette.family(.other, mode), Palette.primaryInk(mode), 0.18)
        default: break
        }
        switch colorMode {
        case .kind:
            return Palette.family(Palette.Family.of(model.kind[node]), mode)
        case .depth:
            return Palette.depth(Int(entry.depth) - 1, mode)
        case .sharing:
            let sizes = model.sizes[node]
            let shared = max(0, sizes.attributed - sizes.retained)
            let fraction = sizes.attributed > 0 ? Float(shared) / Float(sizes.attributed) : 0
            return Palette.sharing(fraction, mode)
        case .delta:
            guard model.hasBaseline else { return Palette.family(.other, mode) }
            return Palette.delta(Float(model.contentDelta[node])
                                 / Float(max(model.sizes[node].allocated, 1)), mode)
        case .reclaim:
            switch model.reclaimTag[node] {
            case 0: return Palette.statusGood
            case 1: return Palette.statusSerious
            case 2: return Palette.statusWarning
            default: return Palette.keepNeutral(mode)
            }
        }
    }
}
