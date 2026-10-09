import AppKit

/// A small rounded tag, tinted by confidence: the same three colours the map
/// uses in "by reclaimability", so the sheet and the map agree at a glance.
final class TagView: NSView {
    private let label = NSTextField(labelWithString: "")
    var tint: NSColor = .secondaryLabelColor { didSet { needsDisplay = true; label.textColor = tint } }
    var text: String = "" { didSet { label.stringValue = text.uppercased(); invalidateIntrinsicContentSize() } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 9, weight: .bold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: label.intrinsicContentSize.width + 12, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
    }
}

extension Reclaim.Confidence {
    var tint: NSColor {
        switch self {
        case .regenerable: return Palette.statusGood.nsColor
        case .cache: return Palette.statusSerious.nsColor
        case .review: return Palette.statusWarning.nsColor
        }
    }
}

/// The reclaim catalogue, made actionable.
///
/// The engine already knew what was safe to remove and what it would really
/// give back; until now the window could only tint it. The figure at the
/// bottom is the *combined* one — these folders share blocks with each other,
/// so ticking a second box can free more than that box is worth on its own.
@MainActor
final class ReclaimSheet: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let session: Session
    private let candidates: [Reclaim.Candidate]
    private var chosen: Set<Int>
    private let onFinish: ([(trashed: URL, original: URL)]) -> Void

    private let panel: NSWindow
    private let table = NSTableView()
    private let total = NSTextField(labelWithString: "")
    private let summary = NSTextField(labelWithString: "")
    private let action = NSButton()

    init(session: Session, onFinish: @escaping ([(trashed: URL, original: URL)]) -> Void) {
        self.session = session
        // Biggest gain first, and the "your call" entries last — they can be
        // looked at but never ticked.
        let ordered = session.reclaim.sorted {
            if ($0.rule.confidence == .review) != ($1.rule.confidence == .review) {
                return $1.rule.confidence == .review
            }
            return $0.sizes.retained > $1.sizes.retained
        }
        self.candidates = ordered
        self.chosen = Set(ordered.indices.filter { ordered[$0].rule.confidence != .review })
        self.onFinish = onFinish
        panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 500),
                         styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.minSize = NSSize(width: 620, height: 360)
        super.init()
        build()
        refreshSummary()
    }

    private func build() {
        let content = NSView()
        panel.contentView = content

        let title = NSTextField(labelWithString: tr("Reclaim space"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let blurb = NSTextField(wrappingLabelWithString: tr("Every entry was kept on evidence — a manifest beside it, a declared cache. "
              + "Sizes are what would actually be freed, clones deducted. Nothing is erased: everything goes to the Trash."))
        blurb.font = .preferredFont(forTextStyle: .caption1)
        blurb.textColor = .secondaryLabelColor

        table.headerView = NSTableHeaderView()
        table.rowHeight = 36
        table.usesAlternatingRowBackgroundColors = true
        table.dataSource = self
        table.delegate = self
        table.style = .inset
        table.allowsEmptySelection = true
        table.doubleAction = #selector(revealRow)
        table.target = self
        for (identifier, title, width) in [("mark", "", 24),
                                           ("path", tr("Folder"), 360),
                                           ("gain", tr("Reclaimable"), 96),
                                           ("rule", tr("Comes back by"), 200)] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = CGFloat(width)
            if identifier == "path" { column.resizingMask = .autoresizingMask }
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        total.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        summary.font = .preferredFont(forTextStyle: .caption1)
        summary.textColor = .secondaryLabelColor
        let figures = NSStackView(views: [total, summary])
        figures.orientation = .vertical
        figures.alignment = .leading
        figures.spacing = 1

        action.title = tr("Move to Trash")
        action.bezelStyle = .rounded
        action.keyEquivalent = "\r"
        action.target = self
        action.action = #selector(performTrash)
        let cancel = NSButton(title: tr("Close"), target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [figures, NSView(), cancel, action])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        for view in [title, blurb, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            blurb.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            blurb.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            blurb.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: blurb.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -14),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
        ])
    }

    func present(over host: NSWindow) {
        host.beginSheet(panel)
    }

    @objc private func close() {
        panel.sheetParent?.endSheet(panel)
    }

    @objc private func toggle(_ sender: NSButton) {
        if sender.state == .on { chosen.insert(sender.tag) } else { chosen.remove(sender.tag) }
        refreshSummary()
    }

    @objc private func revealRow() {
        guard table.clickedRow >= 0, table.clickedRow < candidates.count else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidates[table.clickedRow].path)])
    }

    private func refreshSummary() {
        let picked = chosen.sorted().map { candidates[$0] }
        let combined = Reclaim.combinedFreed(picked, in: session.result)
        let separately = picked.reduce(0) { $0 + $1.sizes.retained }
        total.stringValue = humanBytes(combined)
        var text = tr("%d selected", picked.count)
        if combined > separately + (1 << 20) {
            text += tr(" · %@ of it only comes back together",
                       humanBytes(combined - separately))
        }
        summary.stringValue = text
        action.isEnabled = !picked.isEmpty
    }

    @objc private func performTrash() {
        let picked = chosen.sorted().map { candidates[$0] }
        guard !picked.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = tr("Move %d folders to the Trash?", picked.count)
        alert.informativeText = tr("Nothing is erased: everything goes to the Trash, and can come back from it.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("Move to Trash"))
        alert.addButton(withTitle: tr("Cancel"))
        alert.beginSheetModal(for: panel) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            var moved: [(trashed: URL, original: URL)] = []
            for candidate in picked {
                // Verified again here, not trusted from the scan: the catalogue
                // matched minutes ago and the disk has kept moving since.
                guard Reclaim.verify(candidate.path, rule: candidate.rule) == nil else { continue }
                var trashed: NSURL?
                let original = URL(fileURLWithPath: candidate.path)
                if (try? FileManager.default.trashItem(at: original, resultingItemURL: &trashed)) != nil,
                   let trashed = trashed as URL? {
                    moved.append((trashed, original))
                }
            }
            self.panel.sheetParent?.endSheet(self.panel)
            self.onFinish(moved)
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let candidate = candidates[row]
        let isReview = candidate.rule.confidence == .review

        switch column?.identifier.rawValue {
        case "mark":
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
            box.tag = row
            box.state = chosen.contains(row) ? .on : .off
            box.isEnabled = !isReview
            box.toolTip = isReview ? tr("Never deleted by Cadastre — your call.") : nil
            return box
        case "gain":
            let field = NSTextField(labelWithString: humanBytes(candidate.sizes.retained))
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            field.alignment = .right
            field.textColor = isReview ? .tertiaryLabelColor : .labelColor
            return field
        case "rule":
            let field = NSTextField(labelWithString: candidate.rule.recovery)
            field.font = .systemFont(ofSize: 10.5)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            return field
        default:
            let tag = TagView()
            tag.text = candidate.rule.confidence.title
            tag.tint = candidate.rule.confidence.tint
            let name = NSTextField(labelWithString: (candidate.path as NSString).lastPathComponent)
            name.font = .systemFont(ofSize: 12, weight: .medium)
            name.textColor = isReview ? .secondaryLabelColor : .labelColor
            name.lineBreakMode = .byTruncatingMiddle
            let head = NSStackView(views: [name, tag])
            head.orientation = .horizontal
            head.spacing = 6
            var detail = (candidate.path as NSString).deletingLastPathComponent + " · " + candidate.rule.label
            if let age = candidate.age {
                detail += " · " + tr("modified %@ ago", humanDuration(age))
            }
            let parent = NSTextField(labelWithString: detail)
            parent.font = .systemFont(ofSize: 9.5)
            parent.textColor = .tertiaryLabelColor
            parent.lineBreakMode = .byTruncatingMiddle
            let stack = NSStackView(views: [head, parent])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            return stack
        }
    }
}
