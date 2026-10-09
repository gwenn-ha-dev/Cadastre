import Foundation

enum Style {
    static var enabled = isatty(STDOUT_FILENO) == 1

    static func dim(_ s: String) -> String { enabled ? "\u{1B}[2m\(s)\u{1B}[0m" : s }
    static func bold(_ s: String) -> String { enabled ? "\u{1B}[1m\(s)\u{1B}[0m" : s }
    static func cyan(_ s: String) -> String { enabled ? "\u{1B}[36m\(s)\u{1B}[0m" : s }
    static func yellow(_ s: String) -> String { enabled ? "\u{1B}[33m\(s)\u{1B}[0m" : s }
    static func red(_ s: String) -> String { enabled ? "\u{1B}[31m\(s)\u{1B}[0m" : s }
    static func green(_ s: String) -> String { enabled ? "\u{1B}[32m\(s)\u{1B}[0m" : s }
}

/// Decimal units, because that is what Finder, `diskutil` and the sticker on
/// the box all use. Mixing them with binary units is how a 500 GB disk starts
/// looking like 466 of something.
///
/// The unit names and the decimal separator follow the language: « 6,3 Go »
/// in French, "6.3 GB" in English. The space before the unit is non-breaking
/// so a value never splits across two lines in a narrow inspector.
func humanBytes(_ bytes: Int64) -> String {
    let negative = bytes < 0
    var value = Double(abs(bytes))
    let units = L10n.byteUnits
    var unit = 0
    while value >= 1000 && unit < units.count - 1 {
        value /= 1000
        unit += 1
    }
    let digits = unit == 0 || value >= 100 ? 0 : value >= 10 ? 1 : 2
    let number = value.formatted(.number.precision(.fractionLength(digits)).grouping(.never)
                                    .locale(L10n.language.locale))
    let text = number + "\u{00A0}" + units[unit]
    return negative ? "-" + text : text
}

func bar(_ fraction: Double, width: Int = 12) -> String {
    let filled = max(0, min(width, Int((fraction * Double(width)).rounded())))
    return String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
}

struct Renderer {
    var metric: Metric
    var depth: Int
    var topCount: Int

    /// `compact` keeps only what changes how a number should be read —
    /// purgeable space, snapshots, missing permissions — and drops the
    /// container inventory.
    func volumeSection(_ report: VolumeReport, scanPath: String, compact: Bool = false) -> String {
        var out = ""
        if compact {
            var notes: [String] = []
            if report.purgeable > 0 {
                notes.append(tr("%@ purgeable", humanBytes(report.purgeable)))
            }
            if !report.snapshots.isEmpty {
                notes.append(tr("%d local snapshot(s)", report.snapshots.count))
            }
            if !report.hasFullDiskAccess {
                notes.append(Style.red(tr("no Full Disk Access")))
            }
            guard !notes.isEmpty else { return "" }
            return Style.dim("  \(report.mountPoint) · " + notes.joined(separator: " · ")) + "\n\n"
        }
        out += Style.bold(tr("VOLUME\n"))
        out += "  " + tr("mount point").leftPadded(21) + report.mountPoint + "\n"
        out += "  " + tr("capacity").leftPadded(21) + humanBytes(report.totalCapacity) + "\n"
        out += "  " + tr("free (statfs)").leftPadded(21) + humanBytes(report.availableRaw) + "\n"
        if report.availableForImportant > 0 {
            out += "  " + tr("free as advertised").leftPadded(21)
            out += humanBytes(report.availableForImportant)
            if report.purgeable > 0 {
                out += Style.yellow(tr("   of which %@ purgeable", humanBytes(report.purgeable)))
                out += Style.dim(tr(" (macOS gives it back under pressure, not when you delete)"))
            }
            out += "\n"
        }

        let snapshotsLabel = "  " + tr("local snapshots").leftPadded(21)
        if report.snapshots.isEmpty {
            out += snapshotsLabel + Style.green(tr("none")) + "\n"
        } else {
            out += snapshotsLabel + Style.yellow("\(report.snapshots.count)") + "\n"
            for snapshot in report.snapshots.prefix(5) {
                out += Style.dim("      \(snapshot)\n")
            }
            out += Style.dim(tr("      → while they live, deleting files frees nothing\n"))
        }

        let accessLabel = "  " + tr("Full Disk Access").leftPadded(21)
        if !report.hasFullDiskAccess {
            out += accessLabel + Style.red(tr("NO"))
            out += Style.dim(tr("  Mail, Messages, Safari and iOS backups will read as empty\n"))
        } else {
            out += accessLabel + Style.green(tr("yes")) + "\n"
        }

        for container in report.containers where container.volumes.count > 1 {
            out += "\n" + Style.bold(tr("APFS CONTAINER %@", container.reference))
            out += Style.dim(tr("  (space shared by all its volumes)\n"))
            let scanned = report.mountPoint
            for volume in container.volumes.sorted(by: { $0.used > $1.used }) {
                let mounted = volume.mountPoint
                let isScanned = mounted == scanned
                let marker = isScanned ? Style.cyan("→") : (mounted == nil ? Style.yellow("×") : " ")
                let role = volume.roles.first.map { " [\($0)]" } ?? ""
                let location = mounted ?? tr("not mounted")
                out += "  \(marker) \(humanBytes(volume.used).padded(10))  \(volume.name)\(role)"
                out += Style.dim("  \(location)\n")
            }
            let invisible = container.volumes
                .filter { $0.mountPoint != scanned }
                .reduce(0) { $0 + $1.used }
            if invisible > 0 {
                out += Style.dim("    ")
                out += Style.yellow("\(humanBytes(invisible))")
                out += Style.dim(tr(" used outside the scanned volume — no treemap sees them\n"))
            }
        }
        return out
    }

    func scanSection(_ result: ScanResult) -> String {
        let stats = result.stats
        let root = result.tree.total[Int(result.root)]
        var out = ""

        out += "\n" + Style.bold(tr("MEASURE  ")) + Style.dim(result.tree.name[Int(result.root)]) + "\n"
        let rate = stats.elapsed > 0 ? Double(stats.files + stats.directories) / stats.elapsed : 0
        out += Style.dim(tr("  %@ folders, %@ files in %.2f s  (%.0f entries/s)\n",
                            L10n.count(stats.directories), L10n.count(stats.files), stats.elapsed, rate))

        out += "\n"
        func line(_ label: String, _ value: String, _ note: String, strong: Bool = false) -> String {
            let l = strong ? Style.bold(label.leftPadded(21)) : label.leftPadded(21)
            let v = strong ? Style.bold(value.padded(11)) : value.padded(11)
            return "  " + l + v + "  " + Style.dim(note) + "\n"
        }
        out += line(tr("logical"), humanBytes(root.logical),
                    tr("what the Finder adds up"))
        out += line(tr("allocated"), humanBytes(root.allocated),
                    tr("blocks on disk, clones counted once per file"))
        out += line(tr("real"), humanBytes(root.attributed),
                    tr("fair share of shared blocks — the only additive one"),
                    strong: true)
        out += line(tr("reclaimable"), humanBytes(root.retained),
                    tr("freed if the whole tree is deleted"))

        let inflation = root.allocated - root.attributed
        if inflation > 0 {
            let percent = Double(inflation) / Double(max(root.attributed, 1)) * 100
            out += "\n  " + Style.yellow("→ ") + "\(humanBytes(inflation)) "
            out += tr("(%.1f %%) of clones and hard links that `du` would count twice\n", percent)
        }
        if result.settlement.reachesOutside > 0 {
            out += "  " + Style.yellow("→ ") + "\(humanBytes(result.settlement.reachesOutside)) "
            out += tr("shared with files outside the scope ")
            out += Style.dim(tr("(%d families) — not reclaimable from here\n", result.settlement.straddlingFamilies))
        }
        if stats.datalessFiles > 0 {
            out += "  " + Style.cyan("→ ")
            out += tr("%d evicted iCloud files, %@ logical ",
                      stats.datalessFiles, humanBytes(stats.datalessLogicalBytes))
            out += Style.dim(tr("absent from disk (not downloaded by the scan)\n"))
        }
        if stats.compressedFiles > 0 {
            out += "  " + Style.dim(tr("→ %d compressed files, %@ saved\n",
                                       stats.compressedFiles, humanBytes(stats.compressedSaved)))
        }
        if stats.sparseSaved > 0 {
            out += "  " + Style.dim(tr("→ %@ of holes in sparse files (disk images, VMs)\n",
                                       humanBytes(stats.sparseSaved)))
        }
        if stats.deniedDirectories > 0 {
            out += "  " + Style.red("→ ") + tr("%d folders refused ", stats.deniedDirectories)
            out += Style.dim(tr("— the total above is a floor, not a measure\n"))
            for path in result.deniedPaths.prefix(5) {
                out += Style.dim("      \(path)\n")
            }
        }
        if stats.crossedMounts > 0 {
            out += Style.dim(tr("  → %d mount points / firmlinks not followed\n", stats.crossedMounts))
        }
        if result.stats.cancelled {
            out += "  " + Style.yellow("→ ") + tr("scan interrupted — partial figures\n")
        }
        return out
    }

    func treeSection(_ result: ScanResult) -> String {
        var out = "\n" + Style.bold(tr("TREE  "))
        out += Style.dim(tr("sorted by “%@”\n", metric.rawValue))
        let tree = result.tree
        let rootValue = max(metric.value(tree.total[Int(result.root)]), 1)

        func walk(_ node: Int32, level: Int, prefix: String) {
            guard level <= depth else { return }
            let children = tree.children[Int(node)]
                .filter { metric.value(tree.total[Int($0)]) > 0 }
                .sorted { metric.value(tree.total[Int($0)]) > metric.value(tree.total[Int($1)]) }
            for (index, child) in children.enumerated() {
                let last = index == children.count - 1
                let sizes = tree.total[Int(child)]
                let value = metric.value(sizes)
                let fraction = Double(value) / Double(rootValue)
                let shared = sizes.allocated - sizes.attributed

                var line = prefix + (last ? "└─ " : "├─ ")
                line += Style.dim(bar(fraction, width: 10)) + " "
                line += humanBytes(value).padded(10) + " "
                line += tree.name[Int(child)]
                if tree.skipped[Int(child)] == .denied { line += " " + Style.red(tr("(refused)")) }
                if tree.skipped[Int(child)] == .otherVolume { line += " " + Style.dim(tr("(other volume)")) }
                if tree.skipped[Int(child)] == .ioError { line += " " + Style.red(tr("(read error)")) }
                if shared > value / 4 && shared > 100 << 20 {
                    line += " " + Style.yellow(tr("· %@ shared", humanBytes(shared)))
                }
                out += line + "\n"
                walk(child, level: level + 1, prefix: prefix + (last ? "   " : "│  "))
            }
        }
        walk(result.root, level: 1, prefix: "  ")
        return out
    }

    func topFilesSection(_ result: ScanResult) -> String {
        guard !result.topFiles.isEmpty else { return "" }
        var out = "\n" + Style.bold(tr("LARGEST FILES\n"))
        for file in result.topFiles.prefix(topCount) {
            var line = "  " + humanBytes(file.sizes.attributed).padded(10) + " "
            line += file.path
            var notes: [String] = []
            if file.cloneRefcount > 1 { notes.append(tr("cloned ×%d", file.cloneRefcount)) }
            if file.nlink > 1 { notes.append(tr("%d hard links", file.nlink)) }
            if file.dataless { notes.append("iCloud") }
            if file.compressed { notes.append(tr("compressed")) }
            if file.sizes.logical > file.sizes.allocated * 2 {
                notes.append(tr("sparse, %@ logical", humanBytes(file.sizes.logical)))
            }
            if !notes.isEmpty { line += " " + Style.yellow("(" + notes.joined(separator: ", ") + ")") }
            out += line + "\n"
        }
        return out
    }
}

extension String {
    /// Right-aligned in `width` columns, with one trailing space.
    func padded(_ width: Int) -> String {
        count >= width ? self + " " : String(repeating: " ", count: width - count) + self + " "
    }

    /// Left-aligned in `width` columns.
    func leftPadded(_ width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}
