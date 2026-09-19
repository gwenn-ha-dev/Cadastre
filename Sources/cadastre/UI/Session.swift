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
    /// True when the baseline is the previous measure of a live session, not
    /// a marker on disk: the picker names it, and never offers it as a file.
    private(set) var baselineIsPreviousMeasure = false
    private(set) var model: TreemapModel
    /// Whole-disk mode: the volume's name stands in for the mount point, and
    /// the container's other volumes plus the free space join the map.
    let displayName: String?
    let extras: [TreemapModel.Extra]
    var isWholeDisk: Bool { !extras.isEmpty }
    /// Free space is context, and on a half-empty disk it is most of the
    /// map: off by default, so the map is about what occupies the disk.
    static let showFreeKey = "showFreeSpace"
    static var showsFreeSpace: Bool {
        get { UserDefaults.standard.bool(forKey: showFreeKey) }
        set { UserDefaults.standard.set(newValue, forKey: showFreeKey) }
    }
    var freeSpace: TreemapModel.Extra? { extras.first { $0.kind == .free } }
    private var shownExtras: [TreemapModel.Extra] {
        Session.showsFreeSpace ? extras : extras.filter { $0.kind != .free }
    }

    init(path: String, result: ScanResult, reclaim: [Reclaim.Candidate],
         scannedAt: Date, metric: Metric, baseline: Snapshot? = nil,
         displayName: String? = nil, extras: [TreemapModel.Extra] = []) {
        self.path = path
        self.result = result
        self.reclaim = reclaim
        self.scannedAt = scannedAt
        self.metric = metric
        self.baseline = baseline
        self.displayName = displayName
        self.extras = extras
        let shown = Session.showsFreeSpace ? extras : extras.filter { $0.kind != .free }
        self.model = TreemapModel.build(from: result, metric: metric,
                                        reclaim: reclaim, baseline: baseline, extras: shown)
    }

    /// What the root is called on screen.
    var title: String { displayName ?? (path as NSString).lastPathComponent }

    /// A cancelled scan is a floor, not a measure, and the window says so.
    var isPartial: Bool { result.stats.cancelled }

    func rebuild(metric: Metric? = nil) {
        if let metric { self.metric = metric }
        model = TreemapModel.build(from: result, metric: self.metric,
                                   reclaim: reclaim, baseline: baseline, extras: shownExtras)
    }

    func adopt(baseline: Snapshot?, from file: String?, previousMeasure: Bool = false) {
        self.baseline = baseline
        self.baselinePath = file
        self.baselineIsPreviousMeasure = baseline != nil && previousMeasure
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

/// The disk as a whole: the Data volume is where everything a person can
/// act on lives, and the rest of the container — the sealed system, Preboot,
/// Recovery, VM — plus the free space are added as tiles so the map adds up
/// to the disk's capacity rather than to one folder.
enum WholeDisk {
    static let path = Reclaim.dataVolume

    static var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    struct Context {
        var displayName: String
        var extras: [TreemapModel.Extra]
        var hasFullDiskAccess: Bool
    }

    /// Runs diskutil, so about a second: call it off the main thread.
    static func gather() -> Context {
        let report = VolumeReport.gather(for: path)
        var name = tr(en: "This Mac", fr: "Ce Mac")
        var extras: [TreemapModel.Extra] = []
        if let container = report.containers.first(where: { $0.volumes.contains { $0.mountPoint == path } }) {
            for volume in container.volumes where volume.mountPoint != path && volume.used > 0 {
                if volume.mountPoint == path { continue }
                let role = volume.roles.first ?? ""
                let detail: String
                switch role {
                case "System": detail = tr(en: "macOS itself, sealed and read-only", fr: "macOS lui-même, scellé et en lecture seule")
                case "Preboot": detail = tr(en: "boot files and firmware, managed by macOS", fr: "fichiers de démarrage et firmware, gérés par macOS")
                case "Recovery": detail = tr(en: "recovery system, managed by macOS", fr: "système de secours, géré par macOS")
                case "VM": detail = tr(en: "swap and sleep image, sized by macOS", fr: "swap et image de veille, dimensionnés par macOS")
                case "Update": detail = tr(en: "pending system updates", fr: "mises à jour système en attente")
                default: detail = tr(en: "another volume of the same container", fr: "un autre volume du même conteneur")
                }
                extras.append(TreemapModel.Extra(name: volume.name, detail: detail, bytes: volume.used, kind: .volume))
            }
            if let data = container.volumes.first(where: { $0.mountPoint == path }) {
                name = data.name.replacingOccurrences(of: " - Data", with: "").replacingOccurrences(of: " — Données", with: "")
            }
        }
        var freeDetail = tr(en: "nothing occupies it", fr: "rien ne l'occupe")
        if report.purgeable > 0 {
            freeDetail += tr(en: " · plus %@ purgeable that macOS will give back under pressure",
                             fr: " · plus %@ purgeable que macOS rendra sous pression", humanBytes(report.purgeable))
        }
        extras.append(TreemapModel.Extra(name: tr(en: "free", fr: "libre"), detail: freeDetail,
                                         bytes: report.availableRaw, kind: .free))
        return Context(displayName: name, extras: extras, hasFullDiskAccess: report.hasFullDiskAccess)
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
