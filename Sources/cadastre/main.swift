import Foundation
import CadastreC

// Before anything reads a file — a record loaded by --since included — so that
// nothing from here on can make the kernel download an evicted iCloud file.
cad_set_io_policies()

func usageText() -> String {
    tr("""
    cadastre — disk usage on macOS, without the usual lies

      cadastre [path] [options]

    Options
      --depth N          tree depth shown (default 2)
      --top N            number of large files listed (default 20)
      --metric M         logical | allocated | attributed | exclusive | retained
                         (default: attributed — the fair share of shared blocks)
      --json FILE        export the whole tree as JSON
      --threads N        walk parallelism
      --cross-mounts     descend into other volumes (default: no)
      --nice             walk at low I/O priority
      --volumes          show the volumes only, without scanning
      --keep-files       keep a record per file (implied by --save/--since)
      --lang en|fr       language of every message (default: the system's)
      --no-color

    Map
      --ui               open the treemap (combine with --since to colour the change,
                         --clean to open on the reclaim panel, --find to search)
      --find TEXT        highlight, in the window, every name containing TEXT
      --open changes|reclaim   open the window on that panel
      --disk             the whole disk: the Data volume, framed by the container's
                         other volumes and the free space (in the window: the same map)
      --snapshot FILE    export the map as PNG, without opening a window
      --color-mode M     kind | depth | sharing | delta | reclaim   (default: kind)
      --dark             render the map for a dark background
      --size WxH         export dimensions (default 1280x800)

    Reclaim space
      --clean            list what is safe to delete, with the real gain
      --trash            move those folders to the Trash (never rm), after confirmation
      --yes              do not wait for confirmation

    Over time
      --save FILE        record the scan (“auto”: into the local history)
      --since FILE       compare the current scan to a record (“last”: the most recent)
      --diff A B         compare two records, without scanning anything
      --history          list the records available

    The five measures
      logical     sum of the forks, uncompressed — what the Finder shows
      allocated   blocks on disk, a clone counted in every file
      attributed  fair share of shared blocks — the only additive measure
      exclusive   what deleting this one entry frees
      retained    what deleting the whole subtree frees
    """)
}

var path: String? = nil
var depth = 2
var topCount = 20
var metric = Metric.attributed
var jsonPath: String? = nil
var threads: Int? = nil
var crossMounts = false
var nice = false
var volumesOnly = false
var keepFiles = false
var savePath: String? = nil
var sincePath: String? = nil
var diffPair: (String, String)? = nil
var showHistory = false
var showClean = false
var selfTestLayout = false
var launchUI = false
var snapshotPath: String? = nil
var colorMode = ColorMode.kind
var darkMap = false
var mapSize = CGSize(width: 1280, height: 800)
var doTrash = false
var assumeYes = false
var findText: String? = nil
var openPanel: String? = nil
var wholeDisk = false

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("cadastre: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func usageError(_ message: String) -> Never {
    FileHandle.standardError.write("cadastre: \(message)\n".data(using: .utf8)!)
    exit(2)
}

// The same binary serves both roles. Launched from the Finder there are no
// arguments to read, so being inside a bundle is the signal to open the window;
// run from a terminal it stays a command-line tool unless asked for the map.
// (`-psn_…` is what older launch paths hand a bundled process.)
var arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }
// `-AppleLanguages "(en)"`, `-AppleLocale en_GB` and their kind are user
// defaults handed over on the command line (NSArgumentDomain), read by
// Foundation, not options of ours. Each is a capitalised key and its value.
do {
    var kept: [String] = []
    var position = 0
    while position < arguments.count {
        if arguments[position].range(of: "^-[A-Z][A-Za-z]+$", options: .regularExpression) != nil {
            position += 2
        } else {
            kept.append(arguments[position])
            position += 1
        }
    }
    arguments = kept
}
let launchedFromBundle = Bundle.main.bundlePath.hasSuffix(".app")
if launchedFromBundle && arguments.isEmpty { arguments = ["--ui"] }

// The language is settled before anything else is parsed, so that even the
// error for a bad option comes out in the right one.
if let position = arguments.firstIndex(of: "--lang"), position + 1 < arguments.count {
    guard let chosen = Language(rawValue: arguments[position + 1].lowercased()) else {
        usageError("--lang: en | fr")
    }
    L10n.language = chosen
    arguments.removeSubrange(position...(position + 1))
} else if arguments.contains("--lang") {
    usageError("--lang: en | fr")
}

var index = 0
@MainActor func nextValue(_ flag: String) -> String {
    index += 1
    guard index < arguments.count else {
        usageError(tr("%@ expects a value", flag))
    }
    return arguments[index]
}
@MainActor func nextInt(_ flag: String, atLeast minimum: Int) -> Int {
    let raw = nextValue(flag)
    guard let value = Int(raw), value >= minimum else {
        usageError(tr("%@ expects a whole number, at least %d", flag, minimum))
    }
    return value
}

while index < arguments.count {
    let argument = arguments[index]
    switch argument {
    case "-h", "--help": print(usageText()); exit(0)
    case "--depth": depth = nextInt(argument, atLeast: 0)
    case "--top": topCount = nextInt(argument, atLeast: 0)
    case "--metric":
        let raw = nextValue(argument)
        guard let parsed = Metric(rawValue: raw) else {
            usageError(tr("unknown metric “%@”", raw))
        }
        metric = parsed
    case "--json": jsonPath = nextValue(argument)
    case "--threads": threads = nextInt(argument, atLeast: 1)
    case "--cross-mounts": crossMounts = true
    case "--nice": nice = true
    case "--volumes": volumesOnly = true
    case "--keep-files": keepFiles = true
    case "--save": savePath = nextValue(argument)
    case "--since": sincePath = nextValue(argument)
    case "--diff": diffPair = (nextValue(argument), nextValue(argument))
    case "--history": showHistory = true
    case "--clean": showClean = true
    case "--self-test-layout": selfTestLayout = true
    case "--ui": launchUI = true
    case "--find": findText = nextValue(argument)
    case "--open":
        let raw = nextValue(argument)
        guard ["changes", "reclaim"].contains(raw) else { usageError("--open: changes | reclaim") }
        openPanel = raw
    case "--disk": wholeDisk = true; if path == nil { path = Reclaim.dataVolume }
    case "--snapshot": snapshotPath = nextValue(argument)
    case "--dark": darkMap = true
    case "--color-mode":
        let raw = nextValue(argument)
        guard let parsed = ColorMode(rawValue: raw) else {
            usageError(tr("unknown colour mode “%@”", raw))
        }
        colorMode = parsed
    case "--size":
        let parts = nextValue(argument).lowercased().split(separator: "x").compactMap { Double($0) }
        // Bounded both ways: below a few dozen points there is no map left once
        // the legend is drawn, and Metal refuses a texture past its maximum.
        guard parts.count == 2, parts.allSatisfy({ $0.isFinite && $0 >= 64 && $0 <= 8192 }) else {
            usageError(tr("--size expects WxH, each side between 64 and 8192"))
        }
        mapSize = CGSize(width: parts[0], height: parts[1])
    case "--trash": doTrash = true; showClean = true
    case "--yes", "-y": assumeYes = true
    case "--no-color": Style.enabled = false
    default:
        if argument.hasPrefix("-") {
            usageError(tr("unknown option “%@”", argument))
        }
        path = argument
    }
    index += 1
}

// --trash acts on a plain scan's findings; every other mode exits before
// reaching it, and silently doing nothing is worse than saying so.
if doTrash && (sincePath != nil || diffPair != nil || snapshotPath != nil || launchUI) {
    usageError(tr("--trash only works on a plain scan: not with --since, --diff, --snapshot or --ui"))
}

if showHistory {
    let entries = SnapshotStore.history()
    if entries.isEmpty {
        print(tr("no records in %@", SnapshotStore.directory))
    } else {
        let formatter = L10n.dateFormatter(template: "d MMM yyyy HH:mm")
        for entry in entries {
            let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            print("  \(formatter.string(from: entry.date).padded(20)) \(humanBytes(size).padded(9))  \((entry.path as NSString).lastPathComponent)")
        }
    }
    exit(0)
}

// Comparing two stored scans needs no filesystem access at all.
if let diffPair {
    let renderer = Renderer(metric: metric, depth: depth, topCount: topCount)
    do {
        let before = Snapshot(try ScanIndex.read(diffPair.0))
        let after = Snapshot(try ScanIndex.read(diffPair.1))
        let comparison = ScanDiff.compare(before, after, metric: metric)
        if let jsonPath {
            try writeDiffJSON(comparison, to: jsonPath)
        } else {
            print(renderer.diffSection(comparison))
        }
    } catch {
        fail("\(error)")
    }
    exit(0)
}

// The window owns its own scanning, so it starts before any of the CLI's
// preparation — and with no path at all it simply asks for one.
if launchUI {
    let start = path.map { Walker.resolveRoot(URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path) }
    var startBaseline: Snapshot? = nil
    var startBaselinePath: String? = nil
    if let sincePath {
        var resolved: String? = sincePath
        if sincePath == "last" {
            resolved = start.flatMap { SnapshotStore.mostRecent(for: $0) }
        }
        if let resolved {
            do { startBaseline = Snapshot(try ScanIndex.read(resolved)) }
            catch { fail("\(error)") }
            startBaselinePath = resolved
        }
    }
    runTreemapInterface(initialPath: wholeDisk ? nil : start, metric: metric, baseline: startBaseline,
                        baselinePath: startBaselinePath,
                        colorMode: colorMode, find: findText,
                        openReclaim: showClean || openPanel == "reclaim", openChanges: openPanel == "changes",
                        wholeDisk: wholeDisk)
}

let scanPath = (path ?? FileManager.default.currentDirectoryPath) as NSString
let target = Walker.resolveRoot(URL(fileURLWithPath: scanPath.expandingTildeInPath).standardizedFileURL.path)

var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue else {
    fail(tr("%@ is not a folder", target))
}

let volumeReport = VolumeReport.gather(for: target)
let renderer = Renderer(metric: metric, depth: depth, topCount: topCount)

print(renderer.volumeSection(volumeReport, scanPath: target, compact: sincePath != nil),
      terminator: sincePath != nil ? "" : "\n")
if volumesOnly { exit(0) }

if nice { cad_set_low_io_priority() }

// Loaded up front: a bad path should fail before spending a scan on it.
var baseline: Snapshot? = nil
if let sincePath {
    var resolved = sincePath
    if sincePath == "last" {
        guard let latest = SnapshotStore.mostRecent(for: target) else {
            fail(tr("no record for %@ — run first: cadastre %@ --save auto", target, target))
        }
        resolved = latest
    }
    do { baseline = Snapshot(try ScanIndex.read(resolved)) } catch { fail("\(error)") }
}

var options = Walker.Options()
options.crossMounts = crossMounts
options.keepFiles = keepFiles || savePath != nil || sincePath != nil
    || selfTestLayout || snapshotPath != nil
options.topCount = max(topCount, 40)
if let threads { options.threads = max(1, threads) }

let interactive = isatty(STDERR_FILENO) == 1
if interactive {
    var lastTick = Date.distantPast
    options.progress = { done, queued in
        let now = Date()
        guard now.timeIntervalSince(lastTick) > 0.1 else { return }
        lastTick = now
        let line = tr("\r  %@ folders, %@ queued…    ",
                      L10n.count(done), L10n.count(queued))
        FileHandle.standardError.write(line.data(using: .utf8)!)
    }
}

let scannedAt = Date()
let walker = Walker(options: options)
// Ctrl-C stops the walk and still prints what was measured, marked partial —
// a scan of a whole disk is minutes of work worth keeping a floor of.
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
interrupt.setEventHandler { walker.cancel() }
interrupt.resume()
let result = walker.scan(root: target)
interrupt.cancel()
// From here on Ctrl-C must work again — during the Trash question above all.
signal(SIGINT, SIG_DFL)
if interactive { FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!) }

if savePath != nil && result.stats.cancelled {
    // A partial record would become the next --since baseline, and everything
    // the interrupted walk never reached would read as "appeared".
    FileHandle.standardError.write(tr("cadastre: scan interrupted, not saved — a partial record would make the next comparison wrong\n").data(using: .utf8)!)
} else if let savePath {
    let destination: String
    do {
        destination = savePath == "auto" ? try SnapshotStore.newPath(for: target, at: scannedAt) : savePath
        try ScanIndex.write(result, scannedAt: scannedAt, to: destination)
    } catch {
        fail(tr("could not save: %@", "\(error)"))
    }
    print(Style.dim(tr("  scan saved to %@\n", destination)))
}

if let snapshotPath {
    let model = TreemapModel.build(from: result, metric: metric,
                                   reclaim: Reclaim.find(in: result).candidates,
                                   baseline: baseline)
    do {
        try TreemapSnapshot.write(model: model, colorMode: colorMode,
                                  mode: darkMap ? .dark : .light,
                                  size: mapSize, to: snapshotPath)
        print(Style.dim(tr("  map written to %@", snapshotPath)))
    } catch {
        fail("\(error)")
    }
    exit(0)
}

if selfTestLayout {
    var failed = false
    for metric in Metric.allCases {
        let model = TreemapModel.build(from: result, metric: metric)
        let check = LayoutSelfTest.run(model, bounds: Rect(x: 0, y: 0, width: 1440, height: 900))
        let status = check.passed ? Style.green("ok  ") : Style.red("FAIL")
        print("  \(status) \(metric.rawValue.padded(11)) "
            + tr("%d rectangles, %d frames checked, max error %.4f, median aspect %.2f",
                 check.rectangles, check.checked, check.worstProportionError, check.medianAspect))
        for failure in check.failures.prefix(3) { print("       \(failure)") }
        if !check.passed { failed = true }
    }
    exit(failed ? 1 : 0)
}

// Last of the alternative outputs: a baseline turns the run into a comparison
// only when nothing more specific — a map, a window, a check — was asked for.
if let baseline {
    let comparison = ScanDiff.compare(baseline, Snapshot(result, scannedAt: scannedAt), metric: metric)
    if let jsonPath {
        do { try writeDiffJSON(comparison, to: jsonPath) } catch { fail("\(error)") }
    } else {
        print(renderer.diffSection(comparison))
    }
    exit(0)
}

print(renderer.scanSection(result))

if showClean {
    let findings = Reclaim.find(in: result)
    if let jsonPath {
        do { try writeReclaimJSON(findings, in: result, to: jsonPath) } catch { fail("\(error)") }
        exit(0)
    }
    print()
    print(renderer.reclaimSection(findings, in: result, volume: volumeReport, offerTrash: !doTrash))
    if doTrash {
        _ = Reclaim.trash(findings.candidates, in: result, confirm: !assumeYes, listed: topCount)
    }
    exit(0)
}

print(renderer.treeSection(result))
print(renderer.topFilesSection(result))

if let jsonPath {
    do {
        try exportJSON(result, by: metric, to: jsonPath)
        print(Style.dim(tr("\n  tree written to %@", jsonPath)))
    } catch {
        fail(tr("could not write JSON: %@", "\(error)"))
    }
}

/// A string's JSON body: quotes, backslashes and every control character
/// escaped — a newline in a file name is legal, and must not break the file.
func jsonEscaped(_ s: String) -> String {
    var escaped = ""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": escaped += "\\\""
        case "\\": escaped += "\\\\"
        case "\n": escaped += "\\n"
        case "\t": escaped += "\\t"
        case let c where c.value < 0x20: escaped += String(format: "\\u%04x", c.value)
        default: escaped.unicodeScalars.append(scalar)
        }
    }
    return escaped
}

/// Flat-ish JSON of the directory tree, one object per node, all five metrics
/// kept. This is the feed a treemap renderer consumes.
/// Not on the main actor, and given the metric rather than reading the global:
/// some compilers make the sort closures main-actor closures otherwise, and
/// then refuse to send `tree` into them.
func exportJSON(_ result: ScanResult, by measure: Metric, to file: String) throws {
    let tree = result.tree
    var out = Data()
    out.reserveCapacity(tree.count * 160)

    func append(_ text: String) { out.append(text.data(using: .utf8)!) }
    func escape(_ s: String) -> String { jsonEscaped(s) }

    func emit(_ node: Int32) {
        let sizes = tree.total[Int(node)]
        append("{\"name\":\"\(escape(tree.name[Int(node)]))\"")
        append(",\"logical\":\(sizes.logical)")
        append(",\"allocated\":\(sizes.allocated)")
        append(",\"attributed\":\(sizes.attributed)")
        append(",\"exclusive\":\(sizes.exclusive)")
        append(",\"retained\":\(sizes.retained)")
        append(",\"files\":\(tree.fileCount[Int(node)])")
        if let reason = tree.skipped[Int(node)] {
            append(",\"skipped\":\"\(reason == .denied ? "denied" : reason == .otherVolume ? "other-volume" : "io-error")\"")
        }
        let children = tree.children[Int(node)]
            .filter { measure.value(tree.total[Int($0)]) > 0 }
            .sorted { measure.value(tree.total[Int($0)]) > measure.value(tree.total[Int($1)]) }
        if !children.isEmpty {
            append(",\"children\":[")
            for (position, child) in children.enumerated() {
                if position > 0 { append(",") }
                emit(child)
            }
            append("]")
        }
        append("}")
    }

    append("{\"root\":")
    emit(result.root)
    append(",\"metric\":\"\(measure.rawValue)\"")
    append(",\"scannedAt\":\"\(ISO8601DateFormatter().string(from: Date()))\"")
    append(",\"directories\":\(result.stats.directories)")
    append(",\"files\":\(result.stats.files)")
    append(",\"deniedDirectories\":\(result.stats.deniedDirectories)")
    append(",\"sharedOutsideScope\":\(result.settlement.reachesOutside)")
    append("}")

    try out.write(to: URL(fileURLWithPath: file))
}

/// The diff in machine-readable form — what the verification harness asserts
/// on, and what a future UI will consume rather than re-deriving.
func writeDiffJSON(_ diff: ScanDiff, to file: String) throws {
    func quote(_ s: String) -> String { "\"" + jsonEscaped(s) + "\"" }
    func label(_ status: ScanDiff.Status) -> String {
        switch status {
        case .added: return "added"
        case .removed: return "removed"
        case .changed: return "changed"
        }
    }
    func encode(_ change: ScanDiff.Change) -> String {
        var fields = [
            "\"path\":\(quote(change.path))",
            "\"before\":\(change.before)",
            "\"after\":\(change.after)",
            "\"delta\":\(change.delta)",
            "\"own\":\(change.own)",
            "\"content\":\(change.content)",
            "\"status\":\(quote(label(change.status)))",
        ]
        if change.isSharingOnly(threshold: diff.threshold) { fields.append("\"sharingOnly\":true") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    let iso = ISO8601DateFormatter()
    var text = "{"
    text += "\"root\":\(quote(diff.rootPath))"
    text += ",\"metric\":\(quote(diff.metric.rawValue))"
    text += ",\"before\":\(quote(iso.string(from: diff.before)))"
    text += ",\"after\":\(quote(iso.string(from: diff.after)))"
    text += ",\"totalBefore\":\(diff.totalBefore)"
    text += ",\"totalAfter\":\(diff.totalAfter)"
    text += ",\"delta\":\(diff.delta)"
    text += ",\"threshold\":\(diff.threshold)"
    text += ",\"addedFiles\":\(diff.addedFileCount)"
    text += ",\"removedFiles\":\(diff.removedFileCount)"
    text += ",\"directories\":[" + diff.directories.map(encode).joined(separator: ",") + "]"
    text += ",\"files\":[" + diff.files.map(encode).joined(separator: ",") + "]"
    text += "}"
    try Data(text.utf8).write(to: URL(fileURLWithPath: file), options: .atomic)
}

/// The reclaim report in machine-readable form.
func writeReclaimJSON(_ findings: Reclaim.Findings, in result: ScanResult, to file: String) throws {
    let candidates = findings.candidates
    func quote(_ s: String) -> String { "\"" + jsonEscaped(s) + "\"" }
    func label(_ confidence: Reclaim.Confidence) -> String {
        switch confidence {
        case .regenerable: return "regenerable"
        case .cache: return "cache"
        case .review: return "review"
        }
    }
    let removable = findings.removable
    var text = "{"
    text += "\"root\":\(quote(result.tree.name.first ?? ""))"
    text += ",\"combinedFreed\":\(Reclaim.combinedFreed(removable, in: result))"
    text += ",\"individualSum\":\(removable.reduce(0) { $0 + $1.sizes.retained })"
    text += ",\"candidates\":["
    text += candidates.map { candidate in
        let fields = [
            "\"path\":\(quote(candidate.path))",
            "\"rule\":\(quote(candidate.rule.id))",
            "\"confidence\":\(quote(label(candidate.rule.confidence)))",
            "\"retained\":\(candidate.sizes.retained)",
            "\"attributed\":\(candidate.sizes.attributed)",
            "\"recovery\":\(quote(candidate.rule.recovery))",
        ]
        return "{" + fields.joined(separator: ",") + "}"
    }.joined(separator: ",")
    text += "]}"
    try Data(text.utf8).write(to: URL(fileURLWithPath: file), options: .atomic)
}
