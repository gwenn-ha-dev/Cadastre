import AppKit

/// The legend is present for every mode, always.
///
/// Two of the four light-mode family colours sit under 3:1 against the surface,
/// and the dark green↔yellow pair sits in the CVD floor band. Both are
/// documented relaxations with one condition attached — identity must never
/// rest on colour alone — and this strip, together with the rectangle labels
/// and the inspector, is how that condition is met.
final class LegendView: NSView {
    var mode: ColorMode = .kind { didSet { needsDisplay = true } }
    var hasBaseline = false
    /// Swatches alone say which colour means what; they never say what the
    /// colouring is *about*. The caption does.
    var caption: String = "" { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private var paletteMode: Palette.Mode {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private func entries() -> [(String, RGBA)] {
        let palette = paletteMode
        switch mode {
        case .kind:
            return Palette.Family.allCases.map { ($0.label, Palette.family($0, palette)) }
        case .depth:
            return (0..<5).map { level in
                (level == 0 ? tr("shallow") : level == 4 ? tr("deep") : "",
                 Palette.depth(level, palette))
            }
        case .sharing:
            return [(tr("exclusive"), Palette.sharing(0, palette)),
                    ("", Palette.sharing(0.5, palette)),
                    (tr("fully shared"), Palette.sharing(1, palette))]
        case .delta:
            guard hasBaseline else {
                return [(tr("no marker loaded — place one (⌘S), then choose it under “compare to”"),
                         Palette.mutedInk)]
            }
            // Named for what is measured — bytes written — so the map cannot
            // be read as "this folder shrank" when its share merely moved.
            return [(tr("content deleted"), Palette.delta(-1, palette)),
                    (tr("nothing written"), Palette.delta(0, palette)),
                    (tr("content written"), Palette.delta(1, palette))]
        case .reclaim:
            return [(Reclaim.Confidence.regenerable.title, Palette.statusGood),
                    (Reclaim.Confidence.cache.title, Palette.statusSerious),
                    (Reclaim.Confidence.review.title, Palette.statusWarning),
                    (tr("keep"), Palette.keepNeutral(palette))]
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.plane(paletteMode).nsColor.setFill()
        bounds.fill()

        let ink = Palette.secondaryInk(paletteMode).nsColor
        let font = NSFont.systemFont(ofSize: 10.5)
        let headFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        let items = entries().map { label, color -> (NSAttributedString?, RGBA) in
            (label.isEmpty ? nil : NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: ink]), color)
        }
        let head = caption.isEmpty ? nil : NSAttributedString(string: caption + " ·", attributes: [
            .font: headFont, .foregroundColor: Palette.primaryInk(paletteMode).nsColor,
        ])

        // The strip has to fit: a narrow window would otherwise cut the last
        // family off, and a legend missing an entry is worse than none.
        // Spacing gives first, the caption second.
        func width(gap: CGFloat, withCaption: Bool) -> CGFloat {
            var total: CGFloat = 12
            if withCaption, let head { total += head.size().width + 12 }
            for (text, _) in items {
                total += 14
                total += text.map { $0.size().width + gap } ?? 2
            }
            return total
        }
        var gap: CGFloat = 16
        var showCaption = true
        if width(gap: gap, withCaption: true) > bounds.width {
            gap = 9
            if width(gap: gap, withCaption: true) > bounds.width { showCaption = false }
        }

        var x: CGFloat = 12
        let y = (bounds.height - 10) / 2
        if showCaption, let head {
            head.draw(at: NSPoint(x: x, y: (bounds.height - head.size().height) / 2))
            x += head.size().width + 12
        }

        for (text, color) in items {
            let swatch = NSRect(x: x, y: y, width: 10, height: 10)
            let path = NSBezierPath(roundedRect: swatch, xRadius: 2.5, yRadius: 2.5)
            color.nsColor.setFill()
            path.fill()
            x += 14

            guard let text else { x += 2; continue }
            let size = text.size()
            text.draw(at: NSPoint(x: x, y: (bounds.height - size.height) / 2))
            x += size.width + gap
        }
    }
}
