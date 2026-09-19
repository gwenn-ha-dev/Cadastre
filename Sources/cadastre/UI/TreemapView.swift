import AppKit
import Metal
import Quartz
import QuartzCore
import simd

enum ColorMode: String, CaseIterable {
    case kind, depth, sharing, delta, reclaim

    var label: String {
        switch self {
        case .kind: return tr(en: "By file type", fr: "Par type de fichier")
        case .depth: return tr(en: "By depth", fr: "Par profondeur")
        case .sharing: return tr(en: "By shared blocks", fr: "Par blocs partagés")
        case .delta: return tr(en: "By what changed", fr: "Par ce qui a changé")
        case .reclaim: return tr(en: "By reclaimability", fr: "Par récupérabilité")
        }
    }

    var explanation: String {
        switch self {
        case .kind: return tr(en: "six families of extensions, grey for the rest",
                              fr: "six familles d'extensions, gris pour le reste")
        case .depth: return tr(en: "the deeper the folder, the stronger the tint",
                               fr: "plus le dossier est profond, plus la teinte est soutenue")
        case .sharing: return tr(en: "the darker, the more of its blocks are shared with something else",
                                 fr: "plus c'est foncé, plus les blocs sont partagés avec autre chose")
        case .delta: return tr(en: "what was written or deleted since the loaded marker",
                               fr: "ce qui a été écrit ou supprimé depuis le repère chargé")
        case .reclaim: return tr(en: "what the catalogue deems safe to delete, and on what grounds",
                                 fr: "ce que le catalogue estime sûr à supprimer, et à quel titre")
        }
    }
}

/// Text over the treemap.
///
/// Not decoration: the four-family palette sits in the CVD floor band in dark
/// mode, which is permissible only alongside a secondary encoding, and these
/// labels together with the legend are it. Capped at the largest few hundred
/// rectangles — past that the text is unreadable anyway.
private final class LabelsView: NSView {
    var pass: TreemapLabelPass?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { pass?.draw() }
}

private final class MetalHostView: NSView {
    let metalLayer = CAMetalLayer()
    override func makeBackingLayer() -> CALayer { metalLayer }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// What a search found, for the status line.
struct SearchSummary {
    var matches = 0
    /// Value of the outermost matching entries only: a matching folder and
    /// the files inside it are one hit's worth of bytes, not two.
    var bytes: Int64 = 0
}

final class TreemapView: NSView {
    var onHover: ((Int32?) -> Void)?
    var onSelect: ((Int32) -> Void)?
    var onRootChange: ((Int32) -> Void)?
    var onContextMenu: ((Int32) -> NSMenu?)?
    var onActivate: ((Int32) -> Void)?
    var onSearch: ((SearchSummary?) -> Void)?
    /// Quick Look asks for the selection's URL through this.
    var previewURL: ((Int32) -> URL?)?

    private(set) var rootNode: Int32 = 0
    private(set) var selectedNode: Int32? = nil
    var model: TreemapModel? {
        didSet { rootNode = 0; selectedNode = nil; rebuildMatchMask(); rebuildLayout() }
    }
    var colorMode: ColorMode = .kind {
        didSet { refreshColors() }
    }
    /// Case-insensitive substring over names. A matching folder lights up
    /// everything inside it; everything else fades to the surface.
    var searchQuery: String = "" {
        didSet { guard searchQuery != oldValue else { return }; rebuildMatchMask(); refreshColors() }
    }

    private let renderer = TreemapRenderer()
    private let host = MetalHostView()
    private let labels = LabelsView()
    private var rects: [TreemapRect] = []
    private var fills: [RGBA] = []
    private var hoverIndex = -1
    private var selectedIndex = -1
    private var matchMask: [Bool]? = nil
    private var tracking: NSTrackingArea?
    /// The size the current rectangles were laid out for. During a live
    /// resize they are stretched to the new size rather than recomputed:
    /// forty thousand rectangles per frame is the difference between a
    /// window that follows the pointer and one that stutters behind it.
    private var layoutSize = CGSize.zero

    // Zoom is a transform on the current layout, swapped for a fresh layout
    // once the animation lands. Re-laying out every frame would be both slower
    // and visually wrong — rectangles would reflow mid-flight.
    private var zoomScale = SIMD2<Float>(1, 1)
    private var zoomTranslate = SIMD2<Float>(0, 0)
    private var animation: (from: (SIMD2<Float>, SIMD2<Float>), to: (SIMD2<Float>, SIMD2<Float>),
                            start: CFTimeInterval, duration: CFTimeInterval,
                            completion: (() -> Void)?)?
    private var timer: Timer?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        host.wantsLayer = true
        host.metalLayer.device = renderer?.metalDevice
        host.metalLayer.pixelFormat = .bgra8Unorm
        host.metalLayer.framebufferOnly = true
        host.metalLayer.isOpaque = true
        addSubview(host)
        addSubview(labels)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var paletteMode: Palette.Mode {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        host.frame = bounds
        labels.frame = bounds
        let scale = window?.backingScaleFactor ?? 2
        host.metalLayer.contentsScale = scale
        host.metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if inLiveResize, !rects.isEmpty, layoutSize.width > 0, animation == nil {
            zoomScale = SIMD2(Float(bounds.width / layoutSize.width), Float(bounds.height / layoutSize.height))
            zoomTranslate = SIMD2(0, 0)
            labels.isHidden = true
            render()
        } else {
            rebuildLayout()
        }

        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        zoomScale = SIMD2(1, 1)
        zoomTranslate = SIMD2(0, 0)
        labels.isHidden = false
        rebuildLayout()
    }

    private func rebuildLayout() {
        guard let model, bounds.width > 2, bounds.height > 2 else { return }
        layoutSize = bounds.size
        rects = TreemapLayout.compute(model, root: rootNode,
                                      in: Rect(x: 0, y: 0,
                                               width: Float(bounds.width),
                                               height: Float(bounds.height)))
        hoverIndex = -1
        selectedIndex = selectedNode.flatMap { node in rects.firstIndex { $0.node == node } } ?? -1
        refreshColors()
    }

    private func rebuildMatchMask() {
        guard let model, !searchQuery.isEmpty else {
            matchMask = nil
            onSearch?(nil)
            return
        }
        let needle = searchQuery.lowercased()
        var mask = [Bool](repeating: false, count: model.count)
        var summary = SearchSummary()
        // Parents precede children in the model, so one forward pass both
        // tests each name and inherits a matching ancestor.
        for i in 0..<model.count {
            let parent = Int(model.parent[i])
            let inherited = parent >= 0 && mask[parent]
            let own = model.name[i].lowercased().contains(needle)
            mask[i] = own || inherited
            if own && !inherited {
                summary.matches += 1
                summary.bytes += model.value[i]
            }
        }
        matchMask = mask
        onSearch?(summary)
    }

    private func refreshColors() {
        guard let model else { return }
        let mode = paletteMode
        fills = rects.map { color(for: $0, model: model, mode: mode) }
        renderer?.upload(TreemapRenderer.instances(rects: rects, fills: fills, model: model))
        labels.pass = TreemapLabelPass(model: model, rects: rects, fills: fills, mode: mode, matchMask: matchMask)
        labels.needsDisplay = true
        render()
    }

    private func color(for entry: TreemapRect, model: TreemapModel, mode: Palette.Mode) -> RGBA {
        let node = Int(entry.node)
        let surface = Palette.surface(mode)

        // Directories that still show their contents are frames, not fills: it
        // is what leaves a surface-coloured gutter between every pair of
        // neighbouring fills, and what makes nesting legible without spending
        // a colour on it.
        if model.isDirectory[node] && !entry.isLeaf {
            return RGBA.mix(surface, Palette.primaryInk(mode), 0.05 + 0.02 * Float(min(entry.depth, 4)))
        }

        let base = TreemapSnapshot.colour(for: entry, model: model, colorMode: colorMode, mode: mode)
        if let matchMask, !matchMask[node] {
            return RGBA.mix(base, surface, 0.82)
        }
        return base
    }

    // MARK: - Drawing

    private func render() {
        guard let renderer, bounds.width > 2 else { return }
        let mode = paletteMode
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        renderer.draw(in: host.metalLayer, viewport: bounds.size,
                      pixelScale: window?.backingScaleFactor ?? 2,
                      scale: zoomScale, translate: zoomTranslate,
                      highlight: hoverIndex, selected: selectedIndex,
                      background: Palette.plane(mode),
                      border: Palette.surface(mode),
                      highlightColor: Palette.primaryInk(mode),
                      selectedColor: RGBA(Float(accent.redComponent), Float(accent.greenComponent),
                                          Float(accent.blueComponent)))
    }

    // MARK: - Interaction

    override func mouseMoved(with event: NSEvent) {
        guard animation == nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = TreemapLayout.hitIndex(rects, at: Float(point.x), Float(point.y))
        if index != hoverIndex {
            hoverIndex = index
            onHover?(index >= 0 ? rects[index].node : nil)
            render()
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverIndex = -1
        onHover?(nil)
        render()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard animation == nil, let model else { return }
        let point = convert(event.locationInWindow, from: nil)
        let index = TreemapLayout.hitIndex(rects, at: Float(point.x), Float(point.y))
        guard index >= 0 else { return }
        let hit = rects[index]
        select(index: index)

        if event.clickCount == 2 {
            if model.isDirectory[Int(hit.node)] && hit.node != rootNode && !hit.isLeaf {
                zoom(into: hit.node, from: hit.rect)
            } else {
                onActivate?(hit.node)
            }
        }
    }

    /// Right-click selects what is under the pointer first, so the menu and the
    /// inspector can never describe two different things.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard animation == nil else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let index = TreemapLayout.hitIndex(rects, at: Float(point.x), Float(point.y))
        guard index >= 0 else { return nil }
        hoverIndex = index
        select(index: index)
        return onContextMenu?(rects[index].node)
    }

    /// Arrows move between siblings by position on screen, not by rank in a
    /// list: what is to the right of the selection is what the eye expects
    /// to reach with →.
    override func keyDown(with event: NSEvent) {
        guard animation == nil else { return }
        switch event.keyCode {
        case 51, 53: zoomOut()                       // delete, escape
        case 123: move(dx: -1, dy: 0)                // ←
        case 124: move(dx: 1, dy: 0)                 // →
        case 126: move(dx: 0, dy: -1)                // ↑
        case 125: move(dx: 0, dy: 1)                 // ↓
        case 36, 76:                                 // return, enter
            guard selectedIndex >= 0, let model else { return }
            let hit = rects[selectedIndex]
            if model.isDirectory[Int(hit.node)] && !hit.isLeaf && hit.node != rootNode {
                zoom(into: hit.node, from: hit.rect)
            } else {
                onActivate?(hit.node)
            }
        case 48:                                     // tab: step into the selection
            stepInto()
        case 49:                                     // space: Quick Look
            toggleQuickLook()
        default: super.keyDown(with: event)
        }
    }

    // MARK: - Quick Look

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    private func select(index: Int) {
        guard index >= 0, index < rects.count else { return }
        selectedIndex = index
        selectedNode = rects[index].node
        onSelect?(rects[index].node)
        render()
    }

    func select(node: Int32) {
        guard let index = rects.firstIndex(where: { $0.node == node }) else { return }
        select(index: index)
    }

    private func move(dx: Float, dy: Float) {
        guard let model, !rects.isEmpty else { return }
        // Nothing selected yet: start from the largest thing on screen.
        guard selectedIndex >= 0 else {
            if let first = rects.firstIndex(where: { $0.depth == 1 }) { select(index: first) }
            return
        }
        let current = rects[selectedIndex]
        let parent = model.parent[Int(current.node)]
        let cx = current.rect.x + current.rect.width / 2
        let cy = current.rect.y + current.rect.height / 2

        var best = -1
        var bestScore = Float.greatestFiniteMagnitude
        for (index, candidate) in rects.enumerated() where index != selectedIndex {
            guard model.parent[Int(candidate.node)] == parent else { continue }
            let ox = candidate.rect.x + candidate.rect.width / 2 - cx
            let oy = candidate.rect.y + candidate.rect.height / 2 - cy
            let along = ox * dx + oy * dy
            guard along > 0.5 else { continue }
            let across = abs(ox * dy) + abs(oy * dx)
            // Favour the nearest in the asked direction, with a strong
            // penalty for drifting sideways.
            let score = along + across * 2.5
            if score < bestScore { bestScore = score; best = index }
        }
        if best >= 0 { select(index: best) }
    }

    private func stepInto() {
        guard let model, selectedIndex >= 0 else { return }
        let current = rects[selectedIndex]
        guard model.isDirectory[Int(current.node)], !current.isLeaf else { return }
        if let child = rects.firstIndex(where: { model.parent[Int($0.node)] == current.node }) {
            select(index: child)
        }
    }

    func zoomOut() {
        guard let model, rootNode != 0, animation == nil else { return }
        let previous = rootNode
        rootNode = model.parent[Int(rootNode)]
        selectedNode = previous
        rebuildLayout()
        onRootChange?(rootNode)

        guard let target = rects.first(where: { $0.node == previous }) else { render(); return }
        let scale = SIMD2(Float(bounds.width) / max(target.rect.width, 1),
                          Float(bounds.height) / max(target.rect.height, 1))
        animate(from: (scale, SIMD2(-target.rect.x * scale.x, -target.rect.y * scale.y)),
                to: (SIMD2(1, 1), SIMD2(0, 0)), completion: nil)
    }

    func zoom(into node: Int32, from rect: Rect) {
        let scale = SIMD2(Float(bounds.width) / max(rect.width, 1),
                          Float(bounds.height) / max(rect.height, 1))
        animate(from: (zoomScale, zoomTranslate),
                to: (scale, SIMD2(-rect.x * scale.x, -rect.y * scale.y))) { [weak self] in
            guard let self else { return }
            self.rootNode = node
            self.selectedNode = nil
            self.zoomScale = SIMD2(1, 1)
            self.zoomTranslate = SIMD2(0, 0)
            self.rebuildLayout()
            self.onRootChange?(node)
        }
    }

    func setRoot(_ node: Int32) {
        guard animation == nil else { return }
        rootNode = node
        selectedNode = nil
        hoverIndex = -1
        rebuildLayout()
        onRootChange?(node)
    }

    private func animate(from: (SIMD2<Float>, SIMD2<Float>), to: (SIMD2<Float>, SIMD2<Float>),
                         completion: (() -> Void)?) {
        animation = (from, to, CACurrentMediaTime(), 0.28, completion)
        hoverIndex = -1
        selectedIndex = -1
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            self?.step()
        }
        RunLoop.current.add(timer!, forMode: .eventTracking)
    }

    private func step() {
        guard let animation else { return }
        let elapsed = CACurrentMediaTime() - animation.start
        let t = min(1, elapsed / animation.duration)
        // Ease-out cubic: fast where the eye is following the target, settling
        // gently so the new layout does not appear to snap.
        let eased = Float(1 - pow(1 - t, 3))
        zoomScale = animation.from.0 + (animation.to.0 - animation.from.0) * eased
        zoomTranslate = animation.from.1 + (animation.to.1 - animation.from.1) * eased
        labels.isHidden = t < 1
        render()

        if t >= 1 {
            timer?.invalidate(); timer = nil
            let completion = animation.completion
            self.animation = nil
            labels.isHidden = false
            completion?()
            selectedIndex = selectedNode.flatMap { node in rects.firstIndex { $0.node == node } } ?? -1
            render()
        }
    }
}

extension TreemapView: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        selectedNode.flatMap { previewURL?($0) } == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selectedNode.flatMap { previewURL?($0) } as NSURL?
    }

    /// Arrow keys keep working while the panel is up: they move the selection
    /// underneath and the preview follows.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        switch event.keyCode {
        case 123, 124, 125, 126:
            keyDown(with: event)
            panel.reloadData()
            return true
        default:
            return false
        }
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard selectedIndex >= 0, let window else { return .zero }
        let rect = rects[selectedIndex].rect
        let local = NSRect(x: CGFloat(rect.x), y: CGFloat(rect.y), width: CGFloat(rect.width), height: CGFloat(rect.height))
        return window.convertToScreen(convert(local, to: nil))
    }
}

extension RGBA {
    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a)) }

    var relativeLuminance: Float {
        func channel(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    func contrast(against other: RGBA) -> Float {
        let a = relativeLuminance, b = other.relativeLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// Whichever of black or white reads better on this colour, with the ratio
    /// so the caller can tell whether "better" is actually good enough.
    var readableInk: (NSColor, Float) {
        let onBlack = contrast(against: RGBA(0, 0, 0))
        let onWhite = contrast(against: RGBA(1, 1, 1))
        return onBlack >= onWhite ? (.black, onBlack) : (.white, onWhite)
    }
}
