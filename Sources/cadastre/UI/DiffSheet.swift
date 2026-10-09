import AppKit

/// The text diff, in the window.
///
/// Colouring the map by what changed shows *where*; it does not list *what*,
/// and the question people have — which folder ate forty gigabytes — wants a
/// list sorted by size of change, with the folders that moved bytes themselves
/// first. This is the same `ScanDiff` the command line prints, laid out as a
/// table whose rows lead back to the map.
@MainActor
final class DiffSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private enum Row {
        case header(String)
        case change(ScanDiff.Change, isFile: Bool)
    }

    private let diff: ScanDiff
    private let rootPath: String
    private let rows: [Row]
    private let onNavigate: (String) -> Void

    private let panel: NSWindow
    private let table = NSTableView()

    init(diff: ScanDiff, rootPath: String, onNavigate: @escaping (String) -> Void) {
        self.diff = diff
        self.rootPath = rootPath
        self.onNavigate = onNavigate

        var rows: [Row] = []
        // Folders whose own files moved, or that appeared or vanished: a folder
        // whose change is entirely its children's is only a conduit.
        let movers = diff.directories.filter { abs($0.own) >= diff.threshold || $0.status != .changed }
        if !movers.isEmpty {
            rows.append(.header(tr("Where it moved")))
            rows.append(contentsOf: movers.prefix(60).map { .change($0, isFile: false) })
        }
        let appeared = diff.files.filter { $0.status == .added }
        let grown = diff.files.filter { $0.status == .changed && $0.delta > 0 }
        let shrunk = diff.files.filter { $0.status == .changed && $0.delta < 0 }
        let vanished = diff.files.filter { $0.status == .removed }
        for (title, list) in [(tr("Files that appeared"), appeared),
                              (tr("Files that grew"), grown),
                              (tr("Files that shrank"), shrunk),
                              (tr("Files that vanished"), vanished)] where !list.isEmpty {
            rows.append(.header(title))
            rows.append(contentsOf: list.prefix(40).map { .change($0, isFile: true) })
        }
        self.rows = rows

        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 540),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.minSize = NSSize(width: 640, height: 380)
        super.init()
        build()
    }

    private func build() {
        let content = NSView()
        panel.contentView = content

        let title = NSTextField(labelWithString: tr("What changed"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)

        let formatter = L10n.dateFormatter(template: "d MMM HH:mm")
        let span = NSTextField(labelWithString: tr("from %@ to %@  (%@)",
                                                   formatter.string(from: diff.before), formatter.string(from: diff.after),
                                                   humanDuration(diff.after.timeIntervalSince(diff.before))))
        span.font = .preferredFont(forTextStyle: .caption1)
        span.textColor = .secondaryLabelColor

        let figures = NSStackView()
        figures.orientation = .horizontal
        figures.spacing = 18
        figures.alignment = .firstBaseline
        func figure(_ value: String, _ caption: String, tint: NSColor = .labelColor) -> NSView {
            let number = NSTextField(labelWithString: value)
            number.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
            number.textColor = tint
            let label = NSTextField(labelWithString: caption)
            label.font = .systemFont(ofSize: 10.5)
            label.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [number, label])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 0
            return stack
        }
        figures.addArrangedSubview(figure(humanBytes(diff.totalBefore), tr("before")))
        let arrow = NSTextField(labelWithString: "→")
        arrow.font = .systemFont(ofSize: 20, weight: .light)
        arrow.textColor = .tertiaryLabelColor
        figures.addArrangedSubview(arrow)
        figures.addArrangedSubview(figure(humanBytes(diff.totalAfter), tr("after")))
        figures.addArrangedSubview(figure(signedBytes(diff.delta), diff.metric.title,
                                          tint: diff.delta > 0 ? Palette.statusCritical.nsColor
                                              : diff.delta < 0 ? Palette.statusGood.nsColor : .labelColor))
        let counts = NSTextField(labelWithString: tr("%@ files appeared · %@ vanished · threshold %@",
                                                     L10n.count(diff.addedFileCount), L10n.count(diff.removedFileCount),
                                                     humanBytes(diff.threshold)))
        counts.font = .preferredFont(forTextStyle: .caption1)
        counts.textColor = .tertiaryLabelColor

        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.doubleAction = #selector(navigate)
        table.target = self
        table.usesAlternatingRowBackgroundColors = false
        table.floatsGroupRows = true
        for (identifier, width) in [("delta", 92), ("path", 410), ("note", 220)] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.width = CGFloat(width)
            if identifier == "path" { column.resizingMask = .autoresizingMask }
            table.addTableColumn(column)
        }
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let empty = NSTextField(labelWithString: tr("Nothing significant moved."))
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.isHidden = !rows.isEmpty

        let hint = NSTextField(labelWithString: tr("Double-click a row to find it on the map."))
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .tertiaryLabelColor
        let close = NSButton(title: tr("Close"), target: self, action: #selector(dismiss))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [hint, NSView(), close])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY

        for view in [title, span, figures, counts, scroll, empty, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            span.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            span.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            figures.topAnchor.constraint(equalTo: span.bottomAnchor, constant: 12),
            figures.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            counts.topAnchor.constraint(equalTo: figures.bottomAnchor, constant: 6),
            counts.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.topAnchor.constraint(equalTo: counts.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    func present(over host: NSWindow) { host.beginSheet(panel) }

    @objc private func dismiss() { panel.sheetParent?.endSheet(panel) }

    @objc private func navigate() {
        guard table.clickedRow >= 0, case .change(let change, _) = rows[table.clickedRow] else { return }
        panel.sheetParent?.endSheet(panel)
        onNavigate(change.path)
    }

    private func relative(_ path: String) -> String {
        if path == rootPath { return (rootPath as NSString).lastPathComponent }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !self.tableView(tableView, isGroupRow: row)
    }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .header(let title):
            let field = NSTextField(labelWithString: title.uppercased())
            field.font = .systemFont(ofSize: 10, weight: .semibold)
            field.textColor = .secondaryLabelColor
            return field
        case .change(let change, let isFile):
            switch column?.identifier.rawValue {
            case "delta":
                let value = change.status == .removed ? -change.before : (isFile ? change.delta : (change.status == .changed ? change.own : change.delta))
                let field = NSTextField(labelWithString: signedBytes(value))
                field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                field.alignment = .right
                field.textColor = value > 0 ? Palette.statusCritical.nsColor : Palette.statusGood.nsColor
                return field
            case "note":
                var note = ""
                switch change.status {
                case .added: note = tr("new")
                case .removed: note = tr("gone")
                case .changed:
                    note = isFile ? "\(humanBytes(change.before)) → \(humanBytes(change.after))" : ""
                    if change.isSharingOnly(threshold: diff.threshold) {
                        note = tr("nothing written — cloned elsewhere")
                    }
                }
                let field = NSTextField(labelWithString: note)
                field.font = .systemFont(ofSize: 10.5)
                field.textColor = .secondaryLabelColor
                field.lineBreakMode = .byTruncatingTail
                field.toolTip = note.isEmpty ? nil : note   // still whole in a narrow window
                return field
            default:
                let field = NSTextField(labelWithString: relative(change.path))
                field.font = .systemFont(ofSize: 12, weight: isFile ? .regular : .medium)
                field.lineBreakMode = .byTruncatingMiddle
                field.toolTip = change.path
                return field
            }
        }
    }
}
