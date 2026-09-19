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
    var number: String
    if unit == 0 { number = "\(Int(value))" }
    else if value >= 100 { number = String(format: "%.0f", value) }
    else if value >= 10 { number = String(format: "%.1f", value) }
    else { number = String(format: "%.2f", value) }
    if L10n.decimalSeparator != "." { number = number.replacingOccurrences(of: ".", with: L10n.decimalSeparator) }
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
                notes.append(tr(en: "%@ purgeable", fr: "%@ purgeable", humanBytes(report.purgeable)))
            }
            if !report.snapshots.isEmpty {
                notes.append(tr(en: "%d local snapshot(s)", fr: "%d snapshot(s) local(aux)", report.snapshots.count))
            }
            if !report.hasFullDiskAccess {
                notes.append(Style.red(tr(en: "no Full Disk Access", fr: "sans accès disque complet")))
            }
            guard !notes.isEmpty else { return "" }
            return Style.dim("  \(report.mountPoint) · " + notes.joined(separator: " · ")) + "\n\n"
        }
        out += Style.bold(tr(en: "VOLUME\n", fr: "VOLUME\n"))
        out += "  " + tr(en: "mount point", fr: "point de montage").leftPadded(21) + report.mountPoint + "\n"
        out += "  " + tr(en: "capacity", fr: "capacité").leftPadded(21) + humanBytes(report.totalCapacity) + "\n"
        out += "  " + tr(en: "free (statfs)", fr: "libre (statfs)").leftPadded(21) + humanBytes(report.availableRaw) + "\n"
        if report.availableForImportant > 0 {
            out += "  " + tr(en: "free as advertised", fr: "libre annoncé").leftPadded(21)
            out += humanBytes(report.availableForImportant)
            if report.purgeable > 0 {
                out += Style.yellow(tr(en: "   of which %@ purgeable", fr: "   dont %@ purgeable", humanBytes(report.purgeable)))
                out += Style.dim(tr(en: " (macOS gives it back under pressure, not when you delete)",
                                    fr: " (macOS le rendra sous pression, pas en supprimant)"))
            }
            out += "\n"
        }

        let snapshotsLabel = "  " + tr(en: "local snapshots", fr: "snapshots locaux").leftPadded(21)
        if report.snapshots.isEmpty {
            out += snapshotsLabel + Style.green(tr(en: "none", fr: "aucun")) + "\n"
        } else {
            out += snapshotsLabel + Style.yellow("\(report.snapshots.count)") + "\n"
            for snapshot in report.snapshots.prefix(5) {
                out += Style.dim("      \(snapshot)\n")
            }
            out += Style.dim(tr(en: "      → while they live, deleting files frees nothing\n",
                                fr: "      → tant qu'ils vivent, supprimer des fichiers ne libère rien\n"))
        }

        let accessLabel = "  " + tr(en: "Full Disk Access", fr: "accès disque complet").leftPadded(21)
        if !report.hasFullDiskAccess {
            out += accessLabel + Style.red(tr(en: "NO", fr: "NON"))
            out += Style.dim(tr(en: "  Mail, Messages, Safari and iOS backups will read as empty\n",
                                fr: "  Mail, Messages, Safari, sauvegardes iOS seront lus comme vides\n"))
        } else {
            out += accessLabel + Style.green(tr(en: "yes", fr: "oui")) + "\n"
        }

        for container in report.containers where container.volumes.count > 1 {
            out += "\n" + Style.bold(tr(en: "APFS CONTAINER %@", fr: "CONTENEUR APFS %@", container.reference))
            out += Style.dim(tr(en: "  (space shared by all its volumes)\n", fr: "  (espace partagé entre tous ses volumes)\n"))
            let scanned = report.mountPoint
            for volume in container.volumes.sorted(by: { $0.used > $1.used }) {
                let mounted = volume.mountPoint
                let isScanned = mounted == scanned
                let marker = isScanned ? Style.cyan("→") : (mounted == nil ? Style.yellow("×") : " ")
                let role = volume.roles.first.map { " [\($0)]" } ?? ""
                let location = mounted ?? tr(en: "not mounted", fr: "non monté")
                out += "  \(marker) \(humanBytes(volume.used).padded(10))  \(volume.name)\(role)"
                out += Style.dim("  \(location)\n")
            }
            let invisible = container.volumes
                .filter { $0.mountPoint != scanned }
                .reduce(0) { $0 + $1.used }
            if invisible > 0 {
                out += Style.dim("    ")
                out += Style.yellow("\(humanBytes(invisible))")
                out += Style.dim(tr(en: " used outside the scanned volume — no treemap sees them\n",
                                    fr: " occupés hors du volume scanné — aucun treemap ne les voit\n"))
            }
        }
        return out
    }

    func scanSection(_ result: ScanResult) -> String {
        let stats = result.stats
        let root = result.tree.total[Int(result.root)]
        var out = ""

        out += "\n" + Style.bold(tr(en: "MEASURE  ", fr: "MESURE  ")) + Style.dim(result.tree.name[Int(result.root)]) + "\n"
        let rate = stats.elapsed > 0 ? Double(stats.files + stats.directories) / stats.elapsed : 0
        out += Style.dim(tr(en: "  %@ folders, %@ files in %.2f s  (%.0f entries/s)\n",
                            fr: "  %@ dossiers, %@ fichiers en %.2f s  (%.0f entrées/s)\n",
                            L10n.count(stats.directories), L10n.count(stats.files), stats.elapsed, rate))

        out += "\n"
        func line(_ label: String, _ value: String, _ note: String, strong: Bool = false) -> String {
            let l = strong ? Style.bold(label.leftPadded(21)) : label.leftPadded(21)
            let v = strong ? Style.bold(value.padded(11)) : value.padded(11)
            return "  " + l + v + "  " + Style.dim(note) + "\n"
        }
        out += line(tr(en: "logical", fr: "logique"), humanBytes(root.logical),
                    tr(en: "what the Finder adds up", fr: "ce que le Finder additionne"))
        out += line(tr(en: "allocated", fr: "alloué"), humanBytes(root.allocated),
                    tr(en: "blocks on disk, clones counted once per file", fr: "blocs sur disque, clones comptés une fois par fichier"))
        out += line(tr(en: "real", fr: "réel"), humanBytes(root.attributed),
                    tr(en: "fair share of shared blocks — the only additive one", fr: "part équitable des blocs partagés — le seul additif"),
                    strong: true)
        out += line(tr(en: "reclaimable", fr: "récupérable"), humanBytes(root.retained),
                    tr(en: "freed if the whole tree is deleted", fr: "libéré si on supprime tout l'arbre"))

        let inflation = root.allocated - root.attributed
        if inflation > 0 {
            let percent = Double(inflation) / Double(max(root.attributed, 1)) * 100
            out += "\n  " + Style.yellow("→ ") + "\(humanBytes(inflation)) "
            out += tr(en: "(%.1f %%) of clones and hard links that `du` would count twice\n",
                      fr: "(%.1f %%) de clones et liens durs que `du` compterait en double\n", percent)
        }
        if result.settlement.reachesOutside > 0 {
            out += "  " + Style.yellow("→ ") + "\(humanBytes(result.settlement.reachesOutside)) "
            out += tr(en: "shared with files outside the scope ", fr: "partagés avec des fichiers hors du périmètre ")
            out += Style.dim(tr(en: "(%d families) — not reclaimable from here\n",
                                fr: "(%d familles) — non récupérables ici\n", result.settlement.straddlingFamilies))
        }
        if stats.datalessFiles > 0 {
            out += "  " + Style.cyan("→ ")
            out += tr(en: "%d evicted iCloud files, %@ logical ", fr: "%d fichiers iCloud évincés, %@ logiques ",
                      stats.datalessFiles, humanBytes(stats.datalessLogicalBytes))
            out += Style.dim(tr(en: "absent from disk (not downloaded by the scan)\n",
                                fr: "absents du disque (non rapatriés par le scan)\n"))
        }
        if stats.compressedFiles > 0 {
            out += "  " + Style.dim(tr(en: "→ %d compressed files, %@ saved\n", fr: "→ %d fichiers compressés, %@ économisés\n",
                                       stats.compressedFiles, humanBytes(stats.compressedSaved)))
        }
        if stats.sparseSaved > 0 {
            out += "  " + Style.dim(tr(en: "→ %@ of holes in sparse files (disk images, VMs)\n",
                                       fr: "→ %@ de trous dans des fichiers creux (images disque, VM)\n",
                                       humanBytes(stats.sparseSaved)))
        }
        if stats.deniedDirectories > 0 {
            out += "  " + Style.red("→ ") + tr(en: "%d folders refused ", fr: "%d dossiers refusés ", stats.deniedDirectories)
            out += Style.dim(tr(en: "— the total above is a floor, not a measure\n",
                                fr: "— le total ci-dessus est un plancher, pas une mesure\n"))
            for path in result.deniedPaths.prefix(5) {
                out += Style.dim("      \(path)\n")
            }
        }
        if stats.crossedMounts > 0 {
            out += Style.dim(tr(en: "  → %d mount points / firmlinks not followed\n",
                                fr: "  → %d points de montage / firmlinks non suivis\n", stats.crossedMounts))
        }
        if result.stats.cancelled {
            out += "  " + Style.yellow("→ ") + tr(en: "scan interrupted — partial figures\n", fr: "scan interrompu — chiffres partiels\n")
        }
        return out
    }

    func treeSection(_ result: ScanResult) -> String {
        var out = "\n" + Style.bold(tr(en: "TREE  ", fr: "ARBRE  "))
        out += Style.dim(tr(en: "sorted by “%@”\n", fr: "trié par « %@ »\n", metric.rawValue))
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
                if tree.skipped[Int(child)] == .denied { line += " " + Style.red(tr(en: "(refused)", fr: "(refusé)")) }
                if tree.skipped[Int(child)] == .otherVolume { line += " " + Style.dim(tr(en: "(other volume)", fr: "(autre volume)")) }
                if tree.skipped[Int(child)] == .ioError { line += " " + Style.red(tr(en: "(read error)", fr: "(erreur de lecture)")) }
                if shared > value / 4 && shared > 100 << 20 {
                    line += " " + Style.yellow(tr(en: "· %@ shared", fr: "· %@ partagés", humanBytes(shared)))
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
        var out = "\n" + Style.bold(tr(en: "LARGEST FILES\n", fr: "PLUS GROS FICHIERS\n"))
        for file in result.topFiles.prefix(topCount) {
            var line = "  " + humanBytes(file.sizes.attributed).padded(10) + " "
            line += file.path
            var notes: [String] = []
            if file.cloneRefcount > 1 { notes.append(tr(en: "cloned ×%d", fr: "cloné ×%d", file.cloneRefcount)) }
            if file.nlink > 1 { notes.append(tr(en: "%d hard links", fr: "%d liens durs", file.nlink)) }
            if file.dataless { notes.append("iCloud") }
            if file.compressed { notes.append(tr(en: "compressed", fr: "compressé")) }
            if file.sizes.logical > file.sizes.allocated * 2 {
                notes.append(tr(en: "sparse, %@ logical", fr: "creux, %@ logiques", humanBytes(file.sizes.logical)))
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
