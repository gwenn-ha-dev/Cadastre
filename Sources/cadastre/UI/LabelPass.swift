import AppKit

/// Draws rectangle labels into whatever context is current.
///
/// Shared by the live view and the PNG export on purpose: a snapshot that
/// draws its own idea of the labels stops being evidence about the window.
struct TreemapLabelPass {
    let model: TreemapModel
    let rects: [TreemapRect]
    let fills: [RGBA]
    let mode: Palette.Mode
    /// One flag per model node when a search is active: labels of rectangles
    /// that do not match are drawn faint, like their fills.
    var matchMask: [Bool]? = nil
    var limit = 400

    /// Assumes a flipped context — y downward, origin top-left — which is what
    /// both an NSView with `isFlipped` and the export set up.
    func draw() {
        let secondary = Palette.secondaryInk(mode).nsColor
        var drawn = 0

        for (index, entry) in rects.enumerated() {
            guard drawn < limit else { break }
            // The root has no title band: its name is in the breadcrumb.
            guard entry.depth > 0 else { continue }
            let rect = entry.rect
            let node = Int(entry.node)
            let isFrame = model.isDirectory[node] && !entry.isLeaf
            let faded = matchMask.map { !$0[node] } ?? false

            let font: NSFont
            var color: NSColor
            let box: NSRect
            var halo: NSShadow? = nil
            if isFrame {
                guard rect.width > 46, rect.height > 22 else { continue }
                font = .systemFont(ofSize: 10.5, weight: .semibold)
                color = secondary
                box = NSRect(x: CGFloat(rect.x) + 4, y: CGFloat(rect.y) + 1.5,
                             width: CGFloat(rect.width) - 8, height: 13)
            } else {
                guard rect.width > 44, rect.height > 15 else { continue }
                font = .systemFont(ofSize: 10, weight: .regular)
                // Ink is chosen against the fill underneath, never the theme.
                // Measured rather than guessed from a lightness cutoff: two of
                // the four family colours sit at mid lightness, where a fixed
                // threshold picks whichever side of it they fall on and gets
                // one of them wrong.
                let fill = index < fills.count ? fills[index] : Palette.surface(mode)
                let (ink, ratio) = fill.readableInk
                color = ink
                // Below 3:1 neither ink is comfortable, and dropping the label
                // is not an option — it is the palette's secondary encoding.
                // A hairline halo of the opposite ink rescues it instead.
                if ratio < 3 && !faded {
                    let shadow = NSShadow()
                    shadow.shadowColor = (ink == .white ? NSColor.black : NSColor.white)
                        .withAlphaComponent(0.55)
                    shadow.shadowBlurRadius = 1.5
                    shadow.shadowOffset = .zero
                    halo = shadow
                }
                box = NSRect(x: CGFloat(rect.x) + 3, y: CGFloat(rect.y) + 2,
                             width: CGFloat(rect.width) - 6, height: 12)
            }
            if faded { color = color.withAlphaComponent(0.35) }

            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingMiddle
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: style,
            ]
            if let halo { attributes[.shadow] = halo }
            NSAttributedString(string: model.name[node], attributes: attributes).draw(in: box)
            drawn += 1
        }
    }
}
