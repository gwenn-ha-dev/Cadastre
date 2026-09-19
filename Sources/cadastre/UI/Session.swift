import AppKit

/// One analysed folder, plus whatever is being compared against it.
///
/// The window used to be handed a finished scan and could never look at
/// anything else. Owning the scan instead is what lets the app open a folder,
/// drop a marker and compare against it later without going back to a terminal.
final class Session {
    let path: String
    let result: ScanResult
    let reclaim: [Reclaim.Candidate]
    let scannedAt: Date
    var metric: Metric
    private(set) var baseline: Snapshot?
    private(set) var baselinePath: String?
    private(set) var model: TreemapModel

    init(path: String, result: ScanResult, reclaim: [Reclaim.Candidate],
         scannedAt: Date, metric: Metric, baseline: Snapshot? = nil) {
        self.path = path
        self.result = result
        self.reclaim = reclaim
        self.scannedAt = scannedAt
        self.metric = metric
        self.baseline = baseline
        self.model = TreemapModel.build(from: result, metric: metric,
                                        reclaim: reclaim, baseline: baseline)
    }

    /// A cancelled scan is a floor, not a measure, and the window says so.
    var isPartial: Bool { result.stats.cancelled }

    func rebuild(metric: Metric? = nil) {
        if let metric { self.metric = metric }
        model = TreemapModel.build(from: result, metric: self.metric,
                                   reclaim: reclaim, baseline: baseline)
    }

    func adopt(baseline: Snapshot?, from file: String?) {
        self.baseline = baseline
        self.baselinePath = file
        rebuild()
    }

    /// Write the current scan into the local history, so a later run can
    /// compare against it.
    @discardableResult
    func mark() throws -> String {
        let destination = try SnapshotStore.newPath(for: path, at: scannedAt)
        try ScanIndex.write(result, scannedAt: scannedAt, to: destination)
        return destination
    }

    /// Markers of this folder, newest first, excluding any taken from the very
    /// scan on screen — comparing a scan to itself says nothing.
    func history() -> [(path: String, date: Date)] {
        SnapshotStore.history(for: path).filter { abs($0.date.timeIntervalSince(scannedAt)) > 1 }
    }
}

/// A scan in flight. Cancelling keeps what was measured and delivers it as
/// partial; the window never pretends a stopped scan is a whole one.
final class ScanTask {
    fileprivate let walker: Walker
    fileprivate init(walker: Walker) { self.walker = walker }
    func cancel() { walker.cancel() }
}

/// Runs a scan off the main thread and reports back on it.
enum ScanJob {
    @discardableResult
    static func run(path: String,
                    progress: @escaping (Int, Int) -> Void,
                    completion: @escaping (ScanResult, [Reclaim.Candidate], Date) -> Void) -> ScanTask {
        var options = Walker.Options()
        options.keepFiles = true
        var lastTick = Date.distantPast
        options.progress = { done, queued in
            // Called from worker threads with the walker's lock held, so
            // this hands off and returns rather than touching any UI.
            let now = Date()
            guard now.timeIntervalSince(lastTick) > 0.08 else { return }
            lastTick = now
            DispatchQueue.main.async { progress(done, queued) }
        }
        let walker = Walker(options: options)
        let task = ScanTask(walker: walker)
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            let result = walker.scan(root: path)
            let candidates = Reclaim.find(in: result).candidates
            DispatchQueue.main.async { completion(result, candidates, started) }
        }
        return task
    }
}

/// Folders opened before, most recent first. What the empty window offers,
/// and what the File menu lists — the same eight entries in both places.
enum RecentFolders {
    private static let key = "recentFolders"
    static let limit = 8

    static var all: [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).filter {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static func note(_ path: String) {
        var list = all.filter { $0 != path }
        list.insert(path, at: 0)
        if list.count > limit { list.removeLast(list.count - limit) }
        UserDefaults.standard.set(list, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Ask for a folder. Returns nil if the person changes their mind.
func chooseFolder(startingAt current: String?) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.prompt = tr(en: "Measure", fr: "Analyser")
    panel.message = tr(en: "Choose the folder to measure", fr: "Choisir le dossier à analyser")
    panel.directoryURL = URL(fileURLWithPath: current ?? NSHomeDirectory())
    return panel.runModal() == .OK ? panel.url?.path : nil
}
