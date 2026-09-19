import Foundation

/// A scan, however it was obtained — just walked, or loaded from an index.
struct Snapshot {
    var scannedAt: Date
    var tree: Tree
    var files: FileTable?
    var stats: ScanStats
    var root: Int32 = 0

    init(scannedAt: Date, tree: Tree, files: FileTable?, stats: ScanStats) {
        self.scannedAt = scannedAt
        self.tree = tree
        self.files = files
        self.stats = stats
    }

    init(_ result: ScanResult, scannedAt: Date = Date()) {
        self.init(scannedAt: scannedAt, tree: result.tree, files: result.files, stats: result.stats)
    }

    init(_ loaded: ScanIndex.Loaded) {
        self.init(scannedAt: loaded.header.scannedAt, tree: loaded.tree,
                  files: loaded.files, stats: loaded.stats)
    }
}

/// What changed between two scans of the same tree.
///
/// This is the question a static treemap cannot answer and the one people
/// actually have. You already know Xcode and node_modules are large; what you
/// do not know is which of them ate forty gigabytes last week.
///
/// Nodes are matched by name, level by level — no path strings are built for
/// the matching itself, so a two-million-node comparison is a linear walk.
struct ScanDiff {
    enum Status { case added, removed, changed }

    struct Change {
        var path: String
        var before: Int64
        var after: Int64
        var status: Status
        /// Change in the files held *directly* by this directory, as opposed
        /// to anything a subdirectory accounts for. The directory that shows a
        /// large `own` change is the one that actually did something.
        var own: Int64 = 0
        /// Change in blocks actually written, measured on `allocated`.
        ///
        /// Needed because `attributed` moves for a second reason: cloning a
        /// file into another directory halves the share credited to the
        /// original, so a folder nobody touched can appear to shrink. When
        /// this is flat and the metric is not, no bytes were written — the
        /// accounting simply moved, and the report has to say so.
        var content: Int64 = 0
        var delta: Int64 { after - before }
        func isSharingOnly(threshold: Int64) -> Bool {
            status == .changed && abs(content) * 4 < threshold && abs(own) >= threshold
        }
    }

    var metric: Metric
    var rootPath: String
    var before: Date
    var after: Date
    var totalBefore: Int64 = 0
    var totalAfter: Int64 = 0
    var directories: [Change] = []
    var files: [Change] = []
    var addedFileCount = 0
    var removedFileCount = 0
    var threshold: Int64 = 0

    var delta: Int64 { totalAfter - totalBefore }

    static func compare(_ before: Snapshot, _ after: Snapshot,
                        metric: Metric, threshold explicitThreshold: Int64? = nil) -> ScanDiff {
        var diff = ScanDiff(metric: metric,
                            rootPath: after.tree.name.first ?? "",
                            before: before.scannedAt, after: after.scannedAt)
        diff.totalBefore = metric.value(before.tree.total[Int(before.root)])
        diff.totalAfter = metric.value(after.tree.total[Int(after.root)])

        // Anything smaller than this is noise a human will not act on. Scaled
        // to the size of the change so a small diff still shows detail.
        diff.threshold = explicitThreshold
            ?? max(1 << 20, abs(diff.delta) / 200)

        let oldFiles = before.files?.groupedByDirectory(directoryCount: before.tree.count)
        let newFiles = after.files?.groupedByDirectory(directoryCount: after.tree.count)

        func indexChildren(_ tree: Tree, _ node: Int32) -> [String: Int32] {
            var map = [String: Int32](minimumCapacity: tree.children[Int(node)].count)
            for child in tree.children[Int(node)] { map[tree.name[Int(child)]] = child }
            return map
        }

        func walk(_ oldNode: Int32, _ newNode: Int32, path: String) {
            let oldTotal = metric.value(before.tree.total[Int(oldNode)])
            let newTotal = metric.value(after.tree.total[Int(newNode)])
            let oldOwn = metric.value(before.tree.own[Int(oldNode)])
            let newOwn = metric.value(after.tree.own[Int(newNode)])
            let contentDelta = after.tree.own[Int(newNode)].allocated - before.tree.own[Int(oldNode)].allocated

            if abs(newTotal - oldTotal) >= diff.threshold {
                diff.directories.append(Change(path: path, before: oldTotal, after: newTotal,
                                               status: .changed, own: newOwn - oldOwn,
                                               content: contentDelta))
            }

            if let oldFiles, let newFiles, abs(newOwn - oldOwn) >= diff.threshold {
                compareFiles(oldFiles[Int(oldNode)], newFiles[Int(newNode)], path: path)
            }

            let oldChildren = indexChildren(before.tree, oldNode)
            var seen = Set<String>()
            for newChild in after.tree.children[Int(newNode)] {
                let name = after.tree.name[Int(newChild)]
                seen.insert(name)
                let childPath = path.hasSuffix("/") ? path + name : path + "/" + name
                if let oldChild = oldChildren[name] {
                    walk(oldChild, newChild, path: childPath)
                } else {
                    let size = metric.value(after.tree.total[Int(newChild)])
                    if size >= diff.threshold {
                        diff.directories.append(Change(path: childPath, before: 0, after: size,
                                                       status: .added, own: size))
                    }
                }
            }
            for (name, oldChild) in oldChildren where !seen.contains(name) {
                let size = metric.value(before.tree.total[Int(oldChild)])
                if size >= diff.threshold {
                    let childPath = path.hasSuffix("/") ? path + name : path + "/" + name
                    diff.directories.append(Change(path: childPath, before: size, after: 0,
                                                   status: .removed, own: -size))
                }
            }
        }

        func compareFiles(_ oldBucket: [Int32], _ newBucket: [Int32], path: String) {
            guard let beforeFiles = before.files, let afterFiles = after.files else { return }
            var oldByName = [String: Int32](minimumCapacity: oldBucket.count)
            for index in oldBucket { oldByName[beforeFiles.name[Int(index)]] = index }

            var seen = Set<String>()
            for index in newBucket {
                let name = afterFiles.name[Int(index)]
                seen.insert(name)
                let newSize = metric.value(afterFiles.sizes[Int(index)])
                let filePath = path.hasSuffix("/") ? path + name : path + "/" + name
                if let old = oldByName[name] {
                    let oldSize = metric.value(beforeFiles.sizes[Int(old)])
                    if abs(newSize - oldSize) >= diff.threshold {
                        let written = afterFiles.sizes[Int(index)].allocated - beforeFiles.sizes[Int(old)].allocated
                        diff.files.append(Change(path: filePath, before: oldSize, after: newSize,
                                                 status: .changed, own: newSize - oldSize, content: written))
                    }
                } else {
                    diff.addedFileCount += 1
                    if newSize >= diff.threshold {
                        diff.files.append(Change(path: filePath, before: 0, after: newSize, status: .added))
                    }
                }
            }
            for (name, old) in oldByName where !seen.contains(name) {
                diff.removedFileCount += 1
                let oldSize = metric.value(beforeFiles.sizes[Int(old)])
                if oldSize >= diff.threshold {
                    let filePath = path.hasSuffix("/") ? path + name : path + "/" + name
                    diff.files.append(Change(path: filePath, before: oldSize, after: 0, status: .removed))
                }
            }
        }

        walk(before.root, after.root, path: after.tree.name.first ?? "")

        diff.directories.sort { abs($0.delta) > abs($1.delta) }
        diff.files.sort { abs($0.delta) > abs($1.delta) }
        return diff
    }
}

func humanDuration(_ seconds: TimeInterval) -> String {
    let total = Int(abs(seconds).rounded())
    if total < 90 { return "\(total) s" }
    let minutes = total / 60
    if minutes < 90 { return "\(minutes) min" }
    let hours = minutes / 60
    if hours < 48 { return "\(hours) h \(minutes % 60) min" }
    let days = hours / 24
    return tr(en: "%d d %d h", fr: "%d j %d h", days, hours % 24)
}

func signedBytes(_ bytes: Int64) -> String {
    bytes > 0 ? "+" + humanBytes(bytes) : humanBytes(bytes)
}

extension Renderer {
    func diffSection(_ diff: ScanDiff) -> String {
        var out = Style.bold(tr(en: "CHANGE  ", fr: "ÉCART  ")) + Style.dim(diff.rootPath) + "\n"
        let formatter = L10n.dateFormatter(template: "d MMM HH:mm")
        out += Style.dim(tr(en: "  from %@ to %@", fr: "  du %@ au %@",
                            formatter.string(from: diff.before), formatter.string(from: diff.after)))
        out += Style.dim("  (\(humanDuration(diff.after.timeIntervalSince(diff.before))))\n\n")

        let colour = diff.delta > 0 ? Style.red : Style.green
        out += "  \(metric.rawValue.padded(12)) \(humanBytes(diff.totalBefore).padded(10)) → "
        out += "\(humanBytes(diff.totalAfter).padded(10))   " + Style.bold(colour(signedBytes(diff.delta))) + "\n"
        out += Style.dim(tr(en: "  display threshold %@", fr: "  seuil d'affichage %@", humanBytes(diff.threshold)))
        out += Style.dim(tr(en: "  ·  %d files appeared, %d vanished\n", fr: "  ·  %d fichiers apparus, %d disparus\n",
                            diff.addedFileCount, diff.removedFileCount))

        if diff.directories.isEmpty && diff.files.isEmpty {
            out += "\n  " + Style.green(tr(en: "nothing significant moved", fr: "rien de significatif n'a bougé")) + "\n"
            return out
        }

        // A directory whose change is entirely its children's is just a
        // conduit; the interesting ones moved bytes themselves.
        let movers = diff.directories.filter { abs($0.own) >= diff.threshold || $0.status != .changed }
        if !movers.isEmpty {
            out += "\n" + Style.bold(tr(en: "  WHERE IT MOVED", fr: "  OÙ ÇA A BOUGÉ"))
            out += Style.dim(tr(en: "  (change held by the folder itself)\n", fr: "  (variation propre au dossier)\n"))
            for change in movers.prefix(topCount) {
                let mark = change.status == .added ? Style.green(tr(en: "new  ", fr: "neuf "))
                         : change.status == .removed ? Style.red(tr(en: "gone ", fr: "parti"))
                         : "     "
                let value = change.status == .changed ? change.own : change.delta
                out += "  \(mark) " + (value > 0 ? Style.red : Style.green)(signedBytes(value).padded(11))
                out += " \(change.path)"
                if change.isSharingOnly(threshold: diff.threshold) {
                    out += Style.dim(tr(en: "  nothing written — share of shared blocks redistributed",
                                        fr: "  rien d'écrit — part de blocs partagés redistribuée"))
                }
                out += "\n"
            }
        }

        let grown = diff.files.filter { $0.status == .changed && $0.delta > 0 }
        let appeared = diff.files.filter { $0.status == .added }
        let vanished = diff.files.filter { $0.status == .removed }

        func fileList(_ title: String, _ changes: [ScanDiff.Change], limit: Int) -> String {
            guard !changes.isEmpty else { return "" }
            var text = "\n" + Style.bold("  \(title)\n")
            for change in changes.prefix(limit) {
                let value = change.status == .removed ? -change.before : change.delta
                text += "  " + (value > 0 ? Style.red : Style.green)(signedBytes(value).padded(11))
                text += " \(change.path)"
                if change.status == .changed {
                    text += Style.dim("  (\(humanBytes(change.before)) → \(humanBytes(change.after)))")
                    if change.isSharingOnly(threshold: diff.threshold) {
                        text += Style.dim(tr(en: "  cloned elsewhere, content unchanged", fr: "  cloné ailleurs, contenu inchangé"))
                    }
                }
                text += "\n"
            }
            if changes.count > limit {
                text += Style.dim(tr(en: "  … and %d more\n", fr: "  … et %d autres\n", changes.count - limit))
            }
            return text
        }

        out += fileList(tr(en: "FILES THAT APPEARED", fr: "FICHIERS APPARUS"), appeared, limit: topCount)
        out += fileList(tr(en: "FILES THAT GREW", fr: "FICHIERS QUI ONT GROSSI"), grown, limit: topCount / 2)
        out += fileList(tr(en: "FILES THAT VANISHED", fr: "FICHIERS DISPARUS"), vanished, limit: topCount / 2)
        return out
    }
}
