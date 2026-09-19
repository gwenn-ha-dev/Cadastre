import AppKit
import UniformTypeIdentifiers

// MARK: - Small views

/// A multi-line label that wraps to whatever width it is given.
///
/// An ordinary `NSTextField` reports the width of its whole string as its
/// intrinsic size, so a long file name pushed the inspector — and with it the
/// split divider — wider on every hover. Feeding the current width back as
/// `preferredMaxLayoutWidth` is what makes the label wrap instead of shove.
private final class WrappingLabel: NSTextField {
    override func layout() {
        super.layout()
        if abs(preferredMaxLayoutWidth - bounds.width) > 0.5 {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// A value cell with a proportion bar behind the number: the level's table
/// then reads as a small bar chart, which is what a list of sizes is.
private final class SizeBarCell: NSTableCellView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var tint: NSColor = .controlAccentColor { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        field.alignment = .right
        field.lineBreakMode = .byClipping
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 0, dy: 3)
        tint.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: track, xRadius: 3, yRadius: 3).fill()
        let width = max(3, track.width * max(0, min(1, fraction)))
        let fill = NSRect(x: track.minX, y: track.minY, width: width, height: track.height)
        tint.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
        super.draw(dirtyRect)
    }
}

/// One row of the level table: name, centred vertically.
private final class NameCell: NSTableCellView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        let field = NSTextField(labelWithString: "")
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(field)
        textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A horizontal proportion bar: how much of the current root this entry is.
private final class ShareBar: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 6) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let width = max(fraction > 0 ? 4 : 0, bounds.width * max(0, min(1, fraction)))
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height), xRadius: 3, yRadius: 3).fill()
    }
}

/// The map pane accepts a folder dropped from the Finder.
private final class DropPane: NSView {
    var onDrop: ((String) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func folder(in info: NSDraggingInfo) -> String? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              let url = urls.first else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return url.path
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard folder(in: sender) != nil else { return [] }
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { highlighted = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        guard let path = folder(in: sender) else { return false }
        onDrop?(path)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 6), xRadius: 10, yRadius: 10)
        path.lineWidth = 2
        path.setLineDash([8, 6], count: 2, phase: 0)
        path.stroke()
    }
}

/// What the window shows before anything has been measured: an invitation,
/// and the folders measured before, so the second launch is one click.
private final class EmptyStateView: NSView {
    var onOpen: (() -> Void)?
    var onRecent: ((String) -> Void)?
    private let recents = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView(image: AppIcon.image(size: 112))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 96).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 96).isActive = true

        let title = NSTextField(labelWithString: tr(en: "Measure a folder", fr: "Mesurer un dossier"))
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.alignment = .center
        let subtitle = NSTextField(wrappingLabelWithString: tr(
            en: "Choose one, or drop it here. On APFS, “how big is it” and “what do I get back if I delete it” are two different questions — the map answers both.",
            fr: "Choisissez-en un, ou déposez-le ici. Sur APFS, « quelle taille ça fait » et « qu'est-ce que je récupère si je le supprime » sont deux questions différentes — la carte répond aux deux."))
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 420

        let button = NSButton(title: tr(en: "Choose a folder…", fr: "Choisir un dossier…"), target: self, action: #selector(open))
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"

        recents.orientation = .vertical
        recents.alignment = .leading
        recents.spacing = 2

        let stack = NSStackView(views: [icon, title, subtitle, button, recents])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(28, after: button)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
            recents.widthAnchor.constraint(equalToConstant: 300),
        ])
        reload()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func open() { onOpen?() }

    @objc private func pick(_ sender: NSButton) {
        guard let path = sender.toolTip else { return }
        onRecent?(path)
    }

    func reload() {
        recents.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let paths = RecentFolders.all
        guard !paths.isEmpty else { return }
        let header = NSTextField(labelWithString: tr(en: "RECENT", fr: "RÉCENTS"))
        header.font = .systemFont(ofSize: 10, weight: .semibold)
        header.textColor = .tertiaryLabelColor
        recents.addArrangedSubview(header)
        recents.setCustomSpacing(6, after: header)
        for path in paths {
            let attributed = NSMutableAttributedString(string: (path as NSString).lastPathComponent, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor,
            ])
            attributed.append(NSAttributedString(string: "   " + (path as NSString).deletingLastPathComponent
                .replacingOccurrences(of: NSHomeDirectory(), with: "~"), attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
            let button = NSButton(title: "", target: self, action: #selector(pick(_:)))
            button.attributedTitle = attributed
            button.bezelStyle = .inline
            button.isBordered = false
            button.alignment = .left
            button.toolTip = path
            button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.contentTintColor = .secondaryLabelColor
            recents.addArrangedSubview(button)
        }
    }
}

// MARK: - Window

/// The window around the treemap.
///
/// Most of what is not the map is there because the palette needs it: a legend
/// that is always visible, a breadcrumb so depth is never inferred from colour,
/// and an inspector that names what the pointer is over and lists the current
/// level as a table — the accessible alternative the low-contrast light-mode
/// steps oblige.
///
/// The rest is the loop the tool is actually used in: open a folder, drop a
/// marker, come back next week and compare against it.
final class CadastreWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate,
                            NSMenuItemValidation, NSMenuDelegate, NSSearchFieldDelegate {
    private var session: Session?
    private var scanTask: ScanTask?
    private var pendingBaseline: Snapshot?
    private var pendingBaselinePath: String?
    private var pendingTrail: [String] = []
    private var reclaimSheet: ReclaimSheet?

    let window: NSWindow
    private let treemap = TreemapView()
    private let legend = LegendView()
    private let breadcrumb = NSStackView()
    private let table = NSTableView()
    private let split = NSSplitViewController()
    private let metricPicker = NSPopUpButton()
    private let colorPicker = NSPopUpButton()
    private let baselinePicker = NSPopUpButton()
    private let searchItem = NSSearchToolbarItem(itemIdentifier: .search)
    private let metricLine = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let overlay = NSVisualEffectView()
    private var progressText: NSTextField?
    private let emptyState = EmptyStateView()
    private let recentMenu = NSMenu()

    // Inspector
    private let inspectorName = WrappingLabel(labelWithString: "")
    private let inspectorPath = NSTextField(labelWithString: "")
    private let shareBar = ShareBar()
    private let shareCaption = NSTextField(labelWithString: "")
    private let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private let inspectorPlaceholder = NSTextField(wrappingLabelWithString: "")
    private var inspectorContent: [NSView] = []
    private var rows: [String: (NSTextField, NSTextField, NSGridRow)] = [:]
    private var headerRows: [String: NSGridRow] = [:]

    private var rowNodes: [Int32] = []
    private var rowMax: Int64 = 1
    private var focus: Int32 = 0
    private var defaultMetric: Metric
    private var searchSummary: SearchSummary?
    private var syncingSelection = false
    /// Set from the command line: applied once the first scan has landed.
    var openReclaimOnFirstScan = false
    var initialSearch: String?

    init(metric: Metric, baseline: Snapshot?) {
        self.defaultMetric = metric
        self.pendingBaseline = baseline
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "Cadastre"
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 760, height: 480)
        build()
        // Installing the split view resized the window to the panes' fitting
        // size (their minimums, 760 points). Ask for the real size afterwards,
        // and only then let a saved frame override it.
        window.setContentSize(NSSize(width: 1360, height: 860))
        window.center()
        window.setFrameAutosaveName("cadastre.main")
        showEmptyState()
    }

    // MARK: - Chrome

    /// Controls live in the window's own title bar, the inspector is a real
    /// split-view inspector, and the map keeps everything else.
    ///
    /// The first version stacked a title bar, a control strip and a breadcrumb
    /// before any content — three bands of chrome above the thing you came to
    /// look at. A unified toolbar absorbs the middle one and the split view
    /// gives the panel its material and divider for free.
    private func build() {
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic

        let toolbar = NSToolbar(identifier: "cadastre.toolbar.v2")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        buildControls()

        let map = NSViewController()
        map.view = buildMapPane()
        let inspector = NSViewController()
        inspector.view = buildInspectorPane()

        let content = NSSplitViewItem(viewController: map)
        content.minimumThickness = 420
        let side = NSSplitViewItem(inspectorWithViewController: inspector)
        side.minimumThickness = 280
        side.maximumThickness = 420
        side.canCollapse = true
        split.addSplitViewItem(content)
        split.addSplitViewItem(side)
        window.contentViewController = split

        treemap.onHover = { [weak self] node in self?.hovered(node) }
        treemap.onSelect = { [weak self] node in self?.describe(node, sticky: true) }
        treemap.onRootChange = { [weak self] node in self?.reload(root: node) }
        treemap.onContextMenu = { [weak self] node in self?.contextMenu(for: node) }
        treemap.onActivate = { [weak self] node in self?.reveal(node) }
        treemap.onSearch = { [weak self] summary in
            self?.searchSummary = summary
            self?.refreshStatus()
        }
    }

    private func buildControls() {
        for (picker, action, width) in [(metricPicker, #selector(metricChanged), 168.0),
                                        (colorPicker, #selector(colorChanged), 178.0),
                                        (baselinePicker, #selector(baselineChanged), 186.0)] {
            picker.target = self
            picker.action = action
            picker.bezelStyle = .toolbar
            picker.controlSize = .regular
            picker.translatesAutoresizingMaskIntoConstraints = false
            picker.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        for metric in Metric.allCases {
            metricPicker.addItem(withTitle: metric.title)
            metricPicker.lastItem?.toolTip = metric.explanation
        }
        metricPicker.selectItem(at: Metric.allCases.firstIndex(of: defaultMetric) ?? 2)
        for mode in ColorMode.allCases {
            colorPicker.addItem(withTitle: mode.label)
            colorPicker.lastItem?.toolTip = mode.explanation
        }
        baselinePicker.addItem(withTitle: tr(en: "no marker", fr: "sans repère"))
        baselinePicker.isEnabled = false

        searchItem.searchField.placeholderString = tr(en: "Find by name", fr: "Chercher un nom")
        searchItem.searchField.sendsWholeSearchString = false
        searchItem.searchField.sendsSearchStringImmediately = true
        searchItem.searchField.target = self
        searchItem.searchField.action = #selector(searchChanged)
        searchItem.searchField.delegate = self
        searchItem.preferredWidthForSearchField = 170
        searchItem.resignsFirstResponderWithCancel = true
        searchItem.toolTip = tr(en: "Highlight everything whose name contains this (⌘F)",
                                fr: "Met en avant tout ce dont le nom contient ceci (⌘F)")
    }

    private func buildMapPane() -> NSView {
        let pane = DropPane()
        pane.onDrop = { [weak self] path in self?.scan(path: path) }

        breadcrumb.orientation = .horizontal
        breadcrumb.spacing = 1
        breadcrumb.alignment = .centerY

        let crumbScroll = NSScrollView()
        crumbScroll.documentView = breadcrumb
        crumbScroll.hasHorizontalScroller = false
        crumbScroll.drawsBackground = false
        crumbScroll.horizontalScrollElasticity = .allowed

        let underCrumbs = NSBox(); underCrumbs.boxType = .separator
        let overLegend = NSBox(); overLegend.boxType = .separator

        status.font = .monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.alignment = .right
        status.lineBreakMode = .byTruncatingTail
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        emptyState.onOpen = { [weak self] in self?.openFolder() }
        emptyState.onRecent = { [weak self] path in self?.scan(path: path) }

        overlay.material = .hudWindow
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 12
        overlay.isHidden = true
        let progressLabel = NSTextField(labelWithString: "")
        progressLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        progressText = progressLabel
        let cancel = NSButton(title: tr(en: "Stop", fr: "Arrêter"), target: self, action: #selector(cancelScan))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        cancel.keyEquivalent = "."
        cancel.keyEquivalentModifierMask = [.command]
        let overlayStack = NSStackView(views: [spinner, progressLabel, cancel])
        overlayStack.orientation = .horizontal
        overlayStack.spacing = 12
        overlayStack.setCustomSpacing(18, after: progressLabel)
        overlayStack.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 14, right: 14)
        overlay.addSubview(overlayStack)

        metricLine.font = .preferredFont(forTextStyle: .caption1)
        metricLine.lineBreakMode = .byTruncatingTail
        metricLine.maximumNumberOfLines = 1
        metricLine.cell?.truncatesLastVisibleLine = true
        metricLine.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let topRow = NSStackView(views: [metricLine, status])
        topRow.orientation = .horizontal
        topRow.distribution = .fill
        topRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        metricLine.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        status.setContentCompressionResistancePriority(.required, for: .horizontal)

        let footer = NSStackView(views: [topRow, legend])
        footer.orientation = .vertical
        footer.spacing = 0
        footer.distribution = .fillEqually

        for view in [crumbScroll, underCrumbs, treemap, overLegend, footer,
                     emptyState, overlay, overlayStack, breadcrumb] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        pane.addSubview(crumbScroll); pane.addSubview(underCrumbs); pane.addSubview(treemap)
        pane.addSubview(overLegend); pane.addSubview(footer)
        pane.addSubview(emptyState); pane.addSubview(overlay)

        NSLayoutConstraint.activate([
            crumbScroll.topAnchor.constraint(equalTo: pane.topAnchor),
            crumbScroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            crumbScroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
            crumbScroll.heightAnchor.constraint(equalToConstant: 30),
            breadcrumb.centerYAnchor.constraint(equalTo: crumbScroll.centerYAnchor),
            breadcrumb.leadingAnchor.constraint(equalTo: crumbScroll.leadingAnchor),

            underCrumbs.topAnchor.constraint(equalTo: crumbScroll.bottomAnchor),
            underCrumbs.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            underCrumbs.trailingAnchor.constraint(equalTo: pane.trailingAnchor),

            treemap.topAnchor.constraint(equalTo: underCrumbs.bottomAnchor),
            treemap.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            treemap.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            treemap.bottomAnchor.constraint(equalTo: overLegend.topAnchor),

            overLegend.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            overLegend.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            overLegend.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 48),

            emptyState.topAnchor.constraint(equalTo: pane.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            overlay.centerXAnchor.constraint(equalTo: treemap.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: treemap.centerYAnchor),
            overlayStack.topAnchor.constraint(equalTo: overlay.topAnchor),
            overlayStack.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
            overlayStack.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
            overlayStack.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
        ])
        return pane
    }

    /// Values sit in a grid, not in a tab-stopped string: a grid cannot wrap
    /// a number onto the next line when the panel is narrow, which the string
    /// version did the moment the inspector was dragged below 300 points.
    private func buildInspectorPane() -> NSView {
        let pane = NSVisualEffectView()
        pane.material = .sidebar
        pane.blendingMode = .behindWindow
        pane.state = .followsWindowActiveState

        inspectorName.font = .systemFont(ofSize: 15, weight: .semibold)
        inspectorName.lineBreakMode = .byWordWrapping
        inspectorName.maximumNumberOfLines = 2
        inspectorName.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        inspectorPath.font = .systemFont(ofSize: 10.5)
        inspectorPath.textColor = .tertiaryLabelColor
        inspectorPath.lineBreakMode = .byTruncatingMiddle
        inspectorPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shareCaption.font = .systemFont(ofSize: 10.5)
        shareCaption.textColor = .secondaryLabelColor
        shareCaption.lineBreakMode = .byTruncatingTail
        shareCaption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        grid.rowSpacing = 3
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .trailing
        grid.column(at: 0).width = 118
        grid.translatesAutoresizingMaskIntoConstraints = false

        func header(_ key: String, _ title: String) {
            let field = NSTextField(labelWithString: title.uppercased())
            field.font = .systemFont(ofSize: 9.5, weight: .semibold)
            field.textColor = .tertiaryLabelColor
            let row = grid.addRow(with: [field, NSGridCell.emptyContentView])
            row.mergeCells(in: NSRange(location: 0, length: 2))
            row.topPadding = 12
            headerRows[key] = row
        }
        func row(_ key: String, _ label: String) {
            let name = NSTextField(labelWithString: label)
            name.font = .systemFont(ofSize: 12)
            name.textColor = .secondaryLabelColor
            name.lineBreakMode = .byTruncatingTail
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.alignment = .right
            value.lineBreakMode = .byTruncatingMiddle
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = grid.addRow(with: [name, value])
            rows[key] = (name, value, row)
        }
        header("size", tr(en: "Size", fr: "Taille"))
        row("logical", Metric.logical.shortTitle)
        row("allocated", Metric.allocated.shortTitle)
        row("attributed", Metric.attributed.shortTitle)
        row("retained", Metric.retained.shortTitle)
        row("shared", tr(en: "shared elsewhere", fr: "partagé ailleurs"))
        header("baseline", tr(en: "Since the marker", fr: "Depuis le repère"))
        row("delta", tr(en: "change", fr: "écart"))
        row("written", tr(en: "written", fr: "écrit"))
        header("nature", tr(en: "Nature", fr: "Nature"))
        row("kind", tr(en: "kind", fr: "nature"))
        row("entries", tr(en: "entries", fr: "entrées"))
        row("status", tr(en: "status", fr: "statut"))
        rows["attributed"]?.1.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        rows["attributed"]?.0.font = .systemFont(ofSize: 12, weight: .semibold)
        rows["attributed"]?.0.textColor = .labelColor

        table.headerView = nil
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.backgroundColor = .clear
        table.doubleAction = #selector(tableDoubleClicked)
        table.target = self
        let nameColumn = NSTableColumn(identifier: .init("name")); nameColumn.width = 150
        nameColumn.resizingMask = .autoresizingMask
        let sizeColumn = NSTableColumn(identifier: .init("size")); sizeColumn.width = 92
        table.addTableColumn(nameColumn)
        table.addTableColumn(sizeColumn)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let divider = NSBox(); divider.boxType = .separator
        let levelHeader = NSTextField(labelWithString: tr(en: "THIS LEVEL", fr: "CE NIVEAU"))
        levelHeader.font = .systemFont(ofSize: 9.5, weight: .semibold)
        levelHeader.textColor = .tertiaryLabelColor

        let head = NSStackView(views: [inspectorName, inspectorPath, shareBar, shareCaption])
        head.orientation = .vertical
        head.alignment = .leading
        head.spacing = 3
        head.setCustomSpacing(10, after: inspectorPath)
        head.setCustomSpacing(4, after: shareBar)
        shareBar.translatesAutoresizingMaskIntoConstraints = false

        inspectorPlaceholder.stringValue = tr(en: "Nothing measured yet.\n\nOnce a folder is on the map, this panel describes whatever the pointer is over, and lists the current level.",
                                              fr: "Rien de mesuré pour l'instant.\n\nUne fois un dossier sur la carte, ce panneau décrit ce qui est sous le pointeur, et liste le niveau courant.")
        inspectorPlaceholder.font = .systemFont(ofSize: 12)
        inspectorPlaceholder.textColor = .tertiaryLabelColor
        inspectorPlaceholder.alignment = .center
        inspectorContent = [head, grid, divider, levelHeader, scroll]
        for view in inspectorContent + [inspectorPlaceholder] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pane.addSubview(view)
        }
        // A resting width the panel returns to, at a priority the split view's
        // own constraints and the user's drag both beat.
        let resting = pane.widthAnchor.constraint(equalToConstant: 320)
        resting.priority = .defaultLow

        NSLayoutConstraint.activate([
            resting,
            head.topAnchor.constraint(equalTo: pane.safeAreaLayoutGuide.topAnchor, constant: 14),
            head.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            head.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),
            shareBar.widthAnchor.constraint(equalTo: head.widthAnchor),
            inspectorName.widthAnchor.constraint(equalTo: head.widthAnchor),
            inspectorPath.widthAnchor.constraint(equalTo: head.widthAnchor),
            shareCaption.widthAnchor.constraint(equalTo: head.widthAnchor),
            grid.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 2),
            grid.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -16),
            divider.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 14),
            divider.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            divider.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -12),
            levelHeader.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 8),
            levelHeader.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: levelHeader.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -8),
            inspectorPlaceholder.centerYAnchor.constraint(equalTo: pane.centerYAnchor, constant: -20),
            inspectorPlaceholder.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 28),
            inspectorPlaceholder.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -28),
        ])
        return pane
    }

    // MARK: - Scanning

    func scan(path: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            flash(tr(en: "Folder not found", fr: "Dossier introuvable"), detail: path, warning: true)
            if session == nil { showEmptyState() }
            return
        }
        scanTask?.cancel()
        emptyState.isHidden = true
        overlay.isHidden = false
        spinner.startAnimation(nil)
        progressText?.stringValue = tr(en: "measuring %@…", fr: "analyse de %@…", (path as NSString).lastPathComponent)
        window.title = "Cadastre — \((path as NSString).lastPathComponent)"

        let baseline = pendingBaseline
        let baselineFile = pendingBaselinePath
        pendingBaseline = nil
        pendingBaselinePath = nil
        var task: ScanTask? = nil
        task = ScanJob.run(path: path) { [weak self] done, queued in
            self?.progressText?.stringValue = tr(en: "%@ folders, %@ queued…", fr: "%@ dossiers, %@ en attente…",
                                                 L10n.count(done), L10n.count(queued))
        } completion: { [weak self] result, reclaim, startedAt in
            guard let self, self.scanTask === task else { return }   // superseded by a newer scan
            self.scanTask = nil
            self.overlay.isHidden = true
            self.spinner.stopAnimation(nil)
            RecentFolders.note(path)
            let fresh = Session(path: path, result: result, reclaim: reclaim,
                                scannedAt: startedAt, metric: self.defaultMetric,
                                baseline: baseline)
            if baseline != nil { fresh.adopt(baseline: baseline, from: baselineFile) }
            self.adopt(fresh)
        }
        scanTask = task
    }

    @objc private func cancelScan() {
        scanTask?.cancel()
        progressText?.stringValue = tr(en: "stopping…", fr: "arrêt…")
    }

    private func adopt(_ session: Session) {
        self.session = session

        emptyState.isHidden = true
        inspectorContent.forEach { $0.isHidden = false }
        inspectorPlaceholder.isHidden = true
        treemap.model = session.model
        legend.hasBaseline = session.model.hasBaseline
        refreshBaselineMenu()
        refreshCaptions()
        refreshStatus()
        window.subtitle = session.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        // A rescan should leave you where you were, not at the top.
        let restored = pendingTrail.isEmpty ? 0 : locate(pendingTrail)
        pendingTrail = []
        treemap.setRoot(restored)
        window.makeFirstResponder(treemap)

        if let text = initialSearch {
            initialSearch = nil
            searchItem.searchField.stringValue = text
            treemap.searchQuery = text
        }
        if openReclaimOnFirstScan {
            openReclaimOnFirstScan = false
            DispatchQueue.main.async { [weak self] in self?.showReclaim() }
        }
    }

    func select(colorMode: ColorMode) {
        colorPicker.selectItem(at: ColorMode.allCases.firstIndex(of: colorMode) ?? 0)
        colorChanged()
    }

    private func showEmptyState() {
        emptyState.reload()
        emptyState.isHidden = false
        treemap.model = nil
        window.subtitle = ""
        inspectorContent.forEach { $0.isHidden = true }
        inspectorPlaceholder.isHidden = false
        refreshCaptions()
    }

    private func refreshStatus() {
        guard let session else { status.stringValue = ""; return }
        if let summary = searchSummary {
            status.stringValue = tr(en: "%@ matches · %@", fr: "%@ correspondances · %@",
                                    L10n.count(summary.matches), humanBytes(summary.bytes))
            status.textColor = .controlAccentColor
            return
        }
        let stats = session.result.stats
        var text = tr(en: "%@ folders · %@ files · %.1f s", fr: "%@ dossiers · %@ fichiers · %.1f s",
                      L10n.count(stats.directories), L10n.count(stats.files), stats.elapsed)
        if session.isPartial { text = "⚠ " + tr(en: "partial — scan stopped", fr: "partiel — scan interrompu") + " · " + text }
        else if stats.deniedDirectories > 0 {
            text = "⚠ " + tr(en: "%d folders refused", fr: "%d dossiers refusés", stats.deniedDirectories) + " · " + text
        }
        status.stringValue = text
        status.textColor = session.isPartial || stats.deniedDirectories > 0 ? Palette.statusWarning.nsColor : .secondaryLabelColor
    }

    // MARK: - Actions

    @objc func openFolder() {
        guard let chosen = chooseFolder(startingAt: session?.path) else { return }
        scan(path: chosen)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        scan(path: path)
    }

    @objc func clearRecents() {
        RecentFolders.clear()
        emptyState.reload()
    }

    @objc func placeMarker() {
        guard let session else { return }
        do {
            let file = try session.mark()
            refreshBaselineMenu()
            flash(tr(en: "Marker placed", fr: "Repère posé"),
                  detail: tr(en: "%@\n\nPick it under “compare to” after a later scan to see what changed.",
                             fr: "%@\n\nChoisissez-le dans « comparer à » après un prochain scan pour voir ce qui a bougé.",
                             (file as NSString).lastPathComponent))
        } catch {
            flash(tr(en: "Could not place the marker", fr: "Repère impossible"), detail: "\(error)", warning: true)
        }
    }

    @objc func showReclaim() {
        guard let session else { return }
        guard !session.reclaim.isEmpty else {
            flash(tr(en: "Nothing to reclaim", fr: "Rien à récupérer"),
                  detail: tr(en: "No entry of the catalogue was recognised here.",
                             fr: "Aucune entrée du catalogue n'a été reconnue ici."))
            return
        }
        let sheet = ReclaimSheet(session: session) { [weak self] moved in
            guard let self else { return }
            if moved > 0 { self.rescan() }
        }
        reclaimSheet = sheet
        sheet.present(over: window)
    }

    @objc func exportImage() {
        guard let session else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "cadastre-\((session.path as NSString).lastPathComponent).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let mode: Palette.Mode = window.effectiveAppearance
            .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        do {
            try TreemapSnapshot.write(model: session.model,
                                      colorMode: ColorMode.allCases[colorPicker.indexOfSelectedItem],
                                      mode: mode, size: CGSize(width: 1600, height: 1000),
                                      to: url.path)
            flash(tr(en: "Map exported", fr: "Carte exportée"), detail: url.lastPathComponent)
        } catch {
            flash(tr(en: "Export failed", fr: "Export impossible"), detail: "\(error)", warning: true)
        }
    }

    @objc func rescan() {
        guard let session else { return }
        pendingBaseline = session.baseline
        pendingBaselinePath = session.baselinePath
        pendingTrail = trail()
        scan(path: session.path)
    }

    @objc func focusSearch() {
        window.makeFirstResponder(searchItem.searchField)
    }

    @objc private func searchChanged() {
        treemap.searchQuery = searchItem.searchField.stringValue
    }

    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        treemap.searchQuery = ""
        window.makeFirstResponder(treemap)
    }

    @objc func zoomOut() { treemap.zoomOut() }
    @objc func backToRoot() { treemap.setRoot(0) }
    @objc func toggleInspector() { split.toggleInspector(nil) }

    @objc func chooseMetric(_ sender: NSMenuItem) {
        metricPicker.selectItem(at: sender.tag)
        metricChanged()
    }

    @objc func chooseColor(_ sender: NSMenuItem) {
        colorPicker.selectItem(at: sender.tag)
        colorChanged()
    }

    @objc func chooseLanguage(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? Language, language != L10n.language else { return }
        L10n.store(language)
        let alert = NSAlert()
        // Both languages, on purpose: the person may be switching away from
        // one they do not read.
        alert.messageText = language == .fr ? "Relancer Cadastre en français ?" : "Relaunch Cadastre in English?"
        alert.informativeText = language == .fr
            ? "La langue s'applique au prochain lancement. / The language applies at next launch."
            : "The language applies at next launch. / La langue s'applique au prochain lancement."
        alert.addButton(withTitle: language == .fr ? "Relancer" : "Relaunch")
        alert.addButton(withTitle: language == .fr ? "Plus tard" : "Later")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.relaunch()
        }
    }

    private func relaunch() {
        let arguments = session.map { ["--ui", $0.path] } ?? ["--ui"]
        if Bundle.main.bundlePath.hasSuffix(".app") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            configuration.arguments = arguments
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } else if let executable = Bundle.main.executableURL {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            try? process.run()
            NSApp.terminate(nil)
        }
    }

    @objc private func metricChanged() {
        let chosen = Metric.allCases[metricPicker.indexOfSelectedItem]
        defaultMetric = chosen
        refreshCaptions()
        guard let session, chosen != session.metric else { return }
        let trail = self.trail()
        session.rebuild(metric: chosen)
        treemap.model = session.model
        treemap.setRoot(locate(trail))
    }

    @objc private func colorChanged() {
        let chosen = ColorMode.allCases[colorPicker.indexOfSelectedItem]
        treemap.colorMode = chosen
        legend.mode = chosen
        refreshCaptions()
    }

    /// Spell out, permanently and in the window, what the two menus select.
    /// Their titles alone are short enough to be read as jargon.
    private func refreshCaptions() {
        let metric = Metric.allCases[metricPicker.indexOfSelectedItem]
        let colour = ColorMode.allCases[colorPicker.indexOfSelectedItem]
        let line = NSMutableAttributedString()
        let oneLine = NSMutableParagraphStyle()
        oneLine.lineBreakMode = .byTruncatingTail
        line.append(NSAttributedString(string: tr(en: "Area · ", fr: "Surface · "), attributes: [
            .foregroundColor: NSColor.tertiaryLabelColor,
            .font: NSFont.preferredFont(forTextStyle: .caption1),
        ]))
        line.append(NSAttributedString(string: metric.title, attributes: [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize,
                                     weight: .semibold),
        ]))
        line.append(NSAttributedString(string: " — " + metric.explanation, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.preferredFont(forTextStyle: .caption1),
        ]))
        line.addAttribute(.paragraphStyle, value: oneLine, range: NSRange(location: 0, length: line.length))
        metricLine.attributedStringValue = line
        legend.caption = tr(en: "Colour · ", fr: "Couleur · ") + colour.label
    }

    @objc private func baselineChanged() {
        guard let session else { return }
        let index = baselinePicker.indexOfSelectedItem
        let trail = self.trail()
        let entries = session.history()
        if index <= 0 || index > entries.count {
            session.adopt(baseline: nil, from: nil)
        } else {
            let entry = entries[index - 1]
            do {
                session.adopt(baseline: Snapshot(try ScanIndex.read(entry.path)), from: entry.path)
            } catch {
                flash(tr(en: "Unreadable marker", fr: "Repère illisible"), detail: "\(error)", warning: true)
                baselinePicker.selectItem(at: 0)
                return
            }
        }
        legend.hasBaseline = session.model.hasBaseline
        treemap.model = session.model
        treemap.setRoot(locate(trail))
        // Comparing is the point of a marker: switch the colouring to it.
        if session.model.hasBaseline, colorPicker.indexOfSelectedItem != ColorMode.allCases.firstIndex(of: .delta) {
            colorPicker.selectItem(at: ColorMode.allCases.firstIndex(of: .delta) ?? 0)
            colorChanged()
        }
    }

    private func refreshBaselineMenu() {
        guard let session else { return }
        baselinePicker.removeAllItems()
        baselinePicker.addItem(withTitle: tr(en: "no marker", fr: "sans repère"))
        let formatter = L10n.dateFormatter(template: "d MMM HH:mm")
        let entries = session.history()
        for entry in entries {
            baselinePicker.addItem(withTitle: tr(en: "compare to %@", fr: "comparer à %@", formatter.string(from: entry.date)))
        }
        baselinePicker.isEnabled = !entries.isEmpty
        if let current = session.baselinePath,
           let position = entries.firstIndex(where: { $0.path == current }) {
            baselinePicker.selectItem(at: position + 1)
        } else {
            baselinePicker.selectItem(at: 0)
        }
    }

    @objc private func breadcrumbClicked(_ sender: NSButton) {
        treemap.setRoot(Int32(sender.tag))
    }

    @objc private func tableDoubleClicked() {
        guard let session, table.clickedRow >= 0, table.clickedRow < rowNodes.count else { return }
        let node = rowNodes[table.clickedRow]
        if session.model.isDirectory[Int(node)] { treemap.setRoot(node) } else { reveal(node) }
    }

    private func flash(_ title: String, detail: String, warning: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = warning ? .warning : .informational
        alert.beginSheetModal(for: window)
    }

    // MARK: - Acting on what is under the pointer

    /// Seeing a four-gigabyte file and having no way to touch it was the tool's
    /// biggest gap: the map could name the problem but not open, reveal or
    /// remove it.
    private func contextMenu(for node: Int32) -> NSMenu? {
        guard let session else { return nil }
        let path = session.model.path(of: node)
        let isDirectory = session.model.isDirectory[Int(node)]
        let menu = NSMenu()

        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.isEnabled = enabled
            menu.addItem(item)
        }

        if isDirectory && node != treemap.rootNode {
            add(tr(en: "Zoom Here", fr: "Zoomer ici"), #selector(zoomHere))
            menu.item(at: 0)?.representedObject = node
            menu.addItem(.separator())
        }
        add(tr(en: "Open", fr: "Ouvrir"), #selector(openInFinder))
        add(tr(en: "Reveal in Finder", fr: "Révéler dans le Finder"), #selector(revealInFinder))
        add(tr(en: "Copy Path", fr: "Copier le chemin"), #selector(copyPath))
        menu.addItem(.separator())

        // Refused rather than greyed out where it would be wrong: the folder
        // being measured, and anything the reclaim guards consider off-limits.
        let removable = path != session.path && !Reclaim.isProtected(path)
        let sizes = session.model.sizes[Int(node)]
        add(tr(en: "Move to Trash — frees %@", fr: "Mettre à la corbeille — libère %@", humanBytes(sizes.retained)),
            #selector(trashNode), enabled: removable)
        return menu
    }

    private var selectedPath: String? {
        guard let session, let node = treemap.selectedNode else { return nil }
        return session.model.path(of: node)
    }

    private func reveal(_ node: Int32) {
        guard let session else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.model.path(of: node))])
    }

    @objc private func zoomHere(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? Int32 else { return }
        treemap.setRoot(node)
    }

    @objc func openInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String ?? selectedPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func revealInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String ?? selectedPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc func copyPath(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String ?? selectedPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    @objc func trashNode(_ sender: NSMenuItem) {
        guard let session, let path = sender.representedObject as? String ?? selectedPath else { return }
        guard path != session.path, !Reclaim.isProtected(path) else { return }

        var info = stat()
        guard lstat(path, &info) == 0 else {
            flash(tr(en: "Not found", fr: "Introuvable"),
                  detail: tr(en: "%@\n\nThe map dates from the last scan.", fr: "%@\n\nLa carte date du dernier scan.", path),
                  warning: true)
            return
        }

        let alert = NSAlert()
        alert.messageText = tr(en: "Move to the Trash?", fr: "Mettre à la corbeille ?")
        alert.informativeText = path
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr(en: "Move to Trash", fr: "Mettre à la corbeille"))
        alert.addButton(withTitle: tr(en: "Cancel", fr: "Annuler"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                // Rescan rather than patch the numbers on screen. Every figure
                // here is a claim about the disk, and a stale one after a
                // deletion is exactly the lie this program exists to avoid.
                self?.rescan()
            } catch {
                self?.flash(tr(en: "Could not move it", fr: "Impossible"), detail: error.localizedDescription, warning: true)
            }
        }
    }

    // MARK: - Navigation

    private func trail() -> [String] {
        guard let session else { return [] }
        var names: [String] = []
        var walk = focus
        while walk > 0 {
            names.append(session.model.name[Int(walk)])
            walk = session.model.parent[Int(walk)]
        }
        return names.reversed()
    }

    /// Follow a remembered chain of names down a freshly built model.
    ///
    /// Descending by name costs the depth of the trail; the obvious version —
    /// rebuilding every node's path and comparing strings — costs the whole
    /// tree, a quarter of a million paths built to answer one question. Stops
    /// where the chain stops matching, since a directory can be folded into its
    /// parent or drop out of the map when the metric changes.
    private func locate(_ trail: [String]) -> Int32 {
        guard let model = session?.model else { return 0 }
        var current: Int32 = 0
        for name in trail {
            let first = Int(model.firstChild[Int(current)])
            guard first >= 0 else { return current }
            let range = first..<(first + Int(model.childCount[Int(current)]))
            guard let next = range.first(where: { model.name[$0] == name }) else { return current }
            current = Int32(next)
        }
        return current
    }

    private func reload(root: Int32) {
        guard let model = session?.model else { return }
        focus = root
        rowNodes = []
        let first = Int(model.firstChild[Int(root)])
        if first >= 0 {
            rowNodes = (first..<(first + Int(model.childCount[Int(root)]))).map { Int32($0) }
        }
        rowMax = max(rowNodes.first.map { model.value[Int($0)] } ?? 1, 1)
        table.reloadData()
        rebuildBreadcrumb(for: root)
        describe(root, sticky: true)
    }

    private func rebuildBreadcrumb(for node: Int32) {
        guard let model = session?.model else { return }
        breadcrumb.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var chain: [Int32] = []
        var current = node
        while current >= 0 { chain.append(current); current = model.parent[Int(current)] }

        for (position, item) in chain.reversed().enumerated() {
            if position > 0 {
                let separator = NSTextField(labelWithString: "›")
                separator.textColor = .tertiaryLabelColor
                breadcrumb.addArrangedSubview(separator)
            }
            let title = position == 0
                ? model.name[Int(item)].replacingOccurrences(of: NSHomeDirectory(), with: "~")
                : model.name[Int(item)]
            let control = NSButton(title: title, target: self, action: #selector(breadcrumbClicked(_:)))
            control.bezelStyle = .inline
            control.isBordered = false
            control.tag = Int(item)
            control.font = .systemFont(ofSize: 12, weight: item == node ? .semibold : .regular)
            control.contentTintColor = item == node ? .labelColor : .secondaryLabelColor
            if position == 0 {
                control.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                control.imagePosition = .imageLeading
            }
            breadcrumb.addArrangedSubview(control)
        }
    }

    // MARK: - Inspector

    private func hovered(_ node: Int32?) {
        if let node { describe(node) } else { describe(treemap.selectedNode ?? focus) }
    }

    /// Fill the grid for one node. Rows that do not apply are hidden rather
    /// than rebuilt: this runs on every mouse move.
    private func describe(_ node: Int32?, sticky: Bool = false) {
        guard let session, let node else { return }
        let model = session.model
        let index = Int(node)
        let sizes = model.sizes[index]
        let shared = max(0, sizes.attributed - sizes.retained)

        inspectorName.stringValue = node == 0 ? (model.name[0] as NSString).lastPathComponent : model.name[index]
        inspectorPath.stringValue = model.path(of: node).replacingOccurrences(of: NSHomeDirectory(), with: "~")
        inspectorPath.toolTip = model.path(of: node)

        let rootValue = max(model.value[Int(treemap.rootNode)], 1)
        let fraction = Double(model.value[index]) / Double(rootValue)
        shareBar.fraction = CGFloat(fraction)
        let rootName = treemap.rootNode == 0
            ? (model.name[0] as NSString).lastPathComponent
            : (model.name[Int(treemap.rootNode)] as NSString).lastPathComponent
        shareCaption.stringValue = node == treemap.rootNode
            ? tr(en: "the whole of what is on screen", fr: "tout ce qui est à l'écran")
            : String(format: "%.1f %% ", locale: L10n.language.locale, fraction * 100)
              + tr(en: "of %@", fr: "de %@", rootName)

        func set(_ key: String, _ value: String?, tint: NSColor? = nil) {
            guard let (name, field, row) = rows[key] else { return }
            let hidden = value == nil
            name.isHidden = hidden
            field.isHidden = hidden
            row.isHidden = hidden
            field.stringValue = value ?? ""
            field.textColor = tint ?? .labelColor
        }
        set("logical", humanBytes(sizes.logical))
        set("allocated", humanBytes(sizes.allocated))
        set("attributed", humanBytes(sizes.attributed))
        set("retained", humanBytes(sizes.retained))
        set("shared", shared > 0 ? humanBytes(shared) : nil, tint: Palette.statusSerious.nsColor)

        headerRows["baseline"]?.isHidden = !model.hasBaseline
        if model.hasBaseline {
            let change = model.delta[index]
            let written = model.contentDelta[index]
            set("delta", signedBytes(change),
                tint: change > 0 ? Palette.statusCritical.nsColor : change < 0 ? Palette.statusGood.nsColor : .labelColor)
            set("written", abs(written) * 4 < abs(change)
                ? (written == 0 ? tr(en: "nothing", fr: "rien") : signedBytes(written)) : nil,
                tint: Palette.mutedInk.nsColor)
        } else {
            set("delta", nil)
            set("written", nil)
        }

        // Naming the family is the other half of the palette's secondary
        // encoding: the swatch says which colour, this says which category.
        if model.isDirectory[index] {
            set("kind", tr(en: "folder", fr: "dossier"))
            set("entries", L10n.count(Int(model.childCount[index])))
        } else {
            set("kind", "\(model.kind[index].label) · \(Palette.Family.of(model.kind[index]).label)")
            set("entries", nil)
        }
        switch model.reclaimTag[index] {
        case 0: set("status", Reclaim.Confidence.regenerable.title, tint: Palette.statusGood.nsColor)
        case 1: set("status", Reclaim.Confidence.cache.title, tint: Palette.statusSerious.nsColor)
        case 2: set("status", Reclaim.Confidence.review.title, tint: Palette.statusWarning.nsColor)
        default: set("status", nil)
        }

        if sticky, !syncingSelection {
            syncingSelection = true
            if let row = rowNodes.firstIndex(of: node) {
                table.selectRowIndexes([row], byExtendingSelection: false)
                table.scrollRowToVisible(row)
            } else {
                table.deselectAll(nil)
            }
            syncingSelection = false
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rowNodes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let model = session?.model else { return nil }
        let node = Int(rowNodes[row])
        let isName = tableColumn?.identifier.rawValue == "name"
        if isName {
            let identifier = NSUserInterfaceItemIdentifier("nameCell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NameCell
                ?? { let fresh = NameCell(); fresh.identifier = identifier; return fresh }()
            cell.textField?.stringValue = model.name[node]
            cell.textField?.textColor = model.isDirectory[node] ? .labelColor : .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: 11, weight: model.isDirectory[node] ? .medium : .regular)
            return cell
        }
        let identifier = NSUserInterfaceItemIdentifier("sizeCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SizeBarCell
            ?? { let fresh = SizeBarCell(); fresh.identifier = identifier; return fresh }()
        cell.textField?.stringValue = humanBytes(model.value[node])
        cell.fraction = CGFloat(Double(model.value[node]) / Double(rowMax))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        let row = table.selectedRow
        guard row >= 0, row < rowNodes.count else { return }
        syncingSelection = true
        treemap.select(node: rowNodes[row])
        describe(rowNodes[row])
        syncingSelection = false
    }

    // MARK: - Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(chooseMetric(_:)):
            menuItem.state = menuItem.tag == metricPicker.indexOfSelectedItem ? .on : .off
            return true
        case #selector(chooseColor(_:)):
            menuItem.state = menuItem.tag == colorPicker.indexOfSelectedItem ? .on : .off
            return true
        case #selector(chooseLanguage(_:)):
            menuItem.state = (menuItem.representedObject as? Language) == L10n.language ? .on : .off
            return true
        case #selector(placeMarker), #selector(showReclaim), #selector(exportImage), #selector(rescan),
             #selector(backToRoot), #selector(focusSearch):
            return session != nil
        case #selector(zoomOut):
            return session != nil && treemap.rootNode != 0
        case #selector(copyPath(_:)), #selector(revealInFinder(_:)), #selector(openInFinder(_:)):
            return selectedPath != nil
        case #selector(trashNode(_:)):
            guard let session, let path = selectedPath else { return false }
            return path != session.path && !Reclaim.isProtected(path)
        case #selector(clearRecents):
            return !RecentFolders.all.isEmpty
        default:
            return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        for path in RecentFolders.all {
            let item = NSMenuItem(title: (path as NSString).lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = path
            item.toolTip = path
            item.image = NSWorkspace.shared.icon(forFile: path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(title: tr(en: "Clear Menu", fr: "Effacer le menu"), action: #selector(clearRecents), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    // MARK: - Menu bar

    func buildMenu() -> NSMenu {
        let mainMenu = NSMenu()

        func item(_ title: String, _ action: Selector?, _ key: String = "",
                  modifiers: NSEvent.ModifierFlags = [.command], tag: Int = 0, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.tag = tag
            item.target = target ?? self
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let holder = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach { menu.addItem($0) }
            holder.submenu = menu
            return holder
        }

        // Application
        let language = NSMenuItem(title: tr(en: "Language", fr: "Langue"), action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for candidate in Language.allCases {
            let entry = NSMenuItem(title: candidate.name, action: #selector(chooseLanguage(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = candidate
            languageMenu.addItem(entry)
        }
        language.submenu = languageMenu
        mainMenu.addItem(submenu("Cadastre", [
            item(tr(en: "About Cadastre", fr: "À propos de Cadastre"), #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp),
            .separator(),
            language,
            .separator(),
            item(tr(en: "Hide Cadastre", fr: "Masquer Cadastre"), #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item(tr(en: "Hide Others", fr: "Masquer les autres"), #selector(NSApplication.hideOtherApplications(_:)), "h",
                 modifiers: [.command, .option], target: NSApp),
            item(tr(en: "Show All", fr: "Tout afficher"), #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
            .separator(),
            item(tr(en: "Quit Cadastre", fr: "Quitter Cadastre"), #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ]))

        // File
        recentMenu.delegate = self
        let recent = NSMenuItem(title: tr(en: "Open Recent", fr: "Ouvrir un dossier récent"), action: nil, keyEquivalent: "")
        recent.submenu = recentMenu
        mainMenu.addItem(submenu(tr(en: "File", fr: "Fichier"), [
            item(tr(en: "Open Folder…", fr: "Ouvrir un dossier…"), #selector(openFolder), "o"),
            recent,
            item(tr(en: "Measure Again", fr: "Mesurer à nouveau"), #selector(rescan), "r", modifiers: [.command, .shift]),
            .separator(),
            item(tr(en: "Place a Marker", fr: "Poser un repère"), #selector(placeMarker), "s"),
            item(tr(en: "Reclaim Space…", fr: "Récupérer de l'espace…"), #selector(showReclaim), "r"),
            item(tr(en: "Export Map…", fr: "Exporter la carte…"), #selector(exportImage), "e"),
            .separator(),
            item(tr(en: "Reveal in Finder", fr: "Révéler dans le Finder"), #selector(revealInFinder(_:)), "r", modifiers: [.command, .option]),
            item(tr(en: "Move to Trash", fr: "Mettre à la corbeille"), #selector(trashNode(_:)), "\u{8}"),
            .separator(),
            item(tr(en: "Close", fr: "Fermer"), #selector(NSWindow.performClose(_:)), "w", target: nil),
        ]))

        // Edit
        mainMenu.addItem(submenu(tr(en: "Edit", fr: "Édition"), [
            item(tr(en: "Copy Path", fr: "Copier le chemin"), #selector(copyPath(_:)), "c"),
            .separator(),
            item(tr(en: "Find…", fr: "Rechercher…"), #selector(focusSearch), "f"),
        ]))

        // View
        let metrics = Metric.allCases.enumerated().map { position, metric in
            item(metric.title, #selector(chooseMetric(_:)), "\(position + 1)", tag: position)
        }
        let colours = ColorMode.allCases.enumerated().map { position, mode in
            item(mode.label, #selector(chooseColor(_:)), "\(position + 1)", modifiers: [.command, .option], tag: position)
        }
        mainMenu.addItem(submenu(tr(en: "View", fr: "Présentation"), [
            submenu(tr(en: "Area", fr: "Surface"), metrics),
            submenu(tr(en: "Colour", fr: "Couleur"), colours),
            .separator(),
            item(tr(en: "Zoom Out", fr: "Remonter"), #selector(zoomOut), String(UnicodeScalar(NSUpArrowFunctionKey)!)),
            item(tr(en: "Back to Top", fr: "Revenir à la racine"), #selector(backToRoot),
                 String(UnicodeScalar(NSUpArrowFunctionKey)!), modifiers: [.command, .shift]),
            .separator(),
            item(tr(en: "Show/Hide Inspector", fr: "Afficher/masquer l'inspecteur"), #selector(toggleInspector), "i",
                 modifiers: [.command, .option]),
            item(tr(en: "Enter Full Screen", fr: "Activer le mode plein écran"), #selector(NSWindow.toggleFullScreen(_:)), "f",
                 modifiers: [.command, .control], target: nil),
        ]))

        // Window
        let windowMenu = submenu(tr(en: "Window", fr: "Fenêtre"), [
            item(tr(en: "Minimize", fr: "Placer dans le Dock"), #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
            item(tr(en: "Zoom", fr: "Réduire/agrandir"), #selector(NSWindow.performZoom(_:)), target: nil),
        ])
        mainMenu.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return mainMenu
    }
}

// MARK: - Toolbar

extension NSToolbarItem.Identifier {
    static let open = NSToolbarItem.Identifier("cadastre.open")
    static let mark = NSToolbarItem.Identifier("cadastre.mark")
    static let baseline = NSToolbarItem.Identifier("cadastre.baseline")
    static let reclaim = NSToolbarItem.Identifier("cadastre.reclaim")
    static let metric = NSToolbarItem.Identifier("cadastre.metric")
    static let colour = NSToolbarItem.Identifier("cadastre.colour")
    static let search = NSToolbarItem.Identifier("cadastre.search")
}

extension CadastreWindow: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.open, .mark, .reclaim, .flexibleSpace, .metric, .colour, .baseline,
         .inspectorTrackingSeparator, .search, .toggleInspector]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .search { return searchItem }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.isBordered = true

        switch identifier {
        case .open:
            item.label = tr(en: "Open", fr: "Ouvrir")
            item.toolTip = tr(en: "Choose a folder to measure (⌘O)", fr: "Choisir un dossier à analyser (⌘O)")
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(openFolder)
        case .mark:
            item.label = tr(en: "Marker", fr: "Repère")
            item.toolTip = tr(en: "Save the current state to compare against later (⌘S)",
                              fr: "Enregistrer l'état actuel pour comparer plus tard (⌘S)")
            item.image = NSImage(systemSymbolName: "bookmark", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(placeMarker)
        case .reclaim:
            item.label = tr(en: "Reclaim", fr: "Récupérer")
            item.toolTip = tr(en: "What is safe to delete, and the real gain (⌘R)",
                              fr: "Ce qui est sûr à supprimer, et le gain réel (⌘R)")
            item.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(showReclaim)
        // The three popups carry no caption: their selected titles read on
        // their own, the tooltip names the control, and the footer spells out
        // what the map is currently showing. Captions cost the width that
        // pushed two of them into the overflow menu.
        case .baseline:
            item.label = tr(en: "Compare to", fr: "Comparer à")
            item.toolTip = tr(en: "Compare to a marker placed earlier on this folder",
                              fr: "Comparer à un repère posé plus tôt sur ce dossier")
            item.view = baselinePicker
        case .metric:
            item.label = tr(en: "Area", fr: "Surface")
            item.toolTip = tr(en: "What the area of each rectangle measures (⌘1–5)",
                              fr: "Ce que mesure la surface de chaque rectangle (⌘1–5)")
            item.view = metricPicker
        case .colour:
            item.label = tr(en: "Colour", fr: "Couleur")
            item.toolTip = tr(en: "What the colour of each rectangle means (⌥⌘1–5)",
                              fr: "Ce que signifie la couleur de chaque rectangle (⌥⌘1–5)")
            item.view = colorPicker
        default:
            return nil
        }
        return item
    }
}

// MARK: - Application

/// Dock drops and "Open With" arrive here; everything else goes through the
/// window. The bundle declares folders as an openable type for that reason.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: CadastreWindow
    init(controller: CadastreWindow) { self.controller = controller }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        controller.scan(path: url.path)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

/// Bring up the window. Runs the AppKit loop and does not return.
///
/// The scan happens inside the app now, so this can start with nothing: opened
/// from the Finder with no argument, it shows the picker.
func runTreemapInterface(initialPath: String?, metric: Metric, baseline: Snapshot?,
                         colorMode: ColorMode = .kind, find: String? = nil, openReclaim: Bool = false) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)

    let controller = CadastreWindow(metric: metric, baseline: baseline)
    controller.select(colorMode: baseline != nil && colorMode == .kind ? .delta : colorMode)
    controller.initialSearch = find
    controller.openReclaimOnFirstScan = openReclaim
    let delegate = AppDelegate(controller: controller)
    app.delegate = delegate
    app.mainMenu = controller.buildMenu()
    controller.window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)

    if let initialPath {
        controller.scan(path: initialPath)
    }

    withExtendedLifetime((controller, delegate)) { app.run() }
    exit(0)
}
