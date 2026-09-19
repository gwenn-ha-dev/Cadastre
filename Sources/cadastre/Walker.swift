import Foundation
import CadastreC

struct ScanStats {
    var directories = 0
    var files = 0
    var deniedDirectories = 0
    var entryErrors = 0
    var crossedMounts = 0
    var datalessFiles = 0
    var datalessLogicalBytes: Int64 = 0   // in iCloud, not on this disk
    var compressedFiles = 0
    var compressedSaved: Int64 = 0        // logical minus allocated
    var sparseSaved: Int64 = 0
    var clonedInodes = 0
    var hardLinkedInodes = 0
    var elapsed: TimeInterval = 0
    /// The walk was stopped before the queue drained: every figure is a floor.
    var cancelled = false
}

struct ScanResult {
    var tree: Tree
    var families: Families
    var files: FileTable?
    var root: Int32
    var stats: ScanStats
    var topFiles: [BigFile]
    var settlement: Families.Settlement
    var deniedPaths: [String]
    var rootDevice: UInt32
}

/// Parallel directory walk built on getattrlistbulk(2).
///
/// One syscall returns the name *and* every size attribute for a few hundred
/// entries at once. The readdir-then-lstat-each-child shape that older disk
/// tools use costs one syscall per file and is the reason they take minutes.
final class Walker {
    struct Options {
        var threads: Int = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount))
        var crossMounts = false
        var topCount = 40
        /// Keep a record per file. Needed by the index, the diff and the
        /// treemap; skipped for a plain terminal report.
        var keepFiles = false
        var progress: ((Int, Int) -> Void)? = nil   // directories done, queued
    }

    private let options: Options
    private let tree = Tree()
    private let files = FileTable()
    private var families = Families()
    private var stats = ScanStats()
    private var topFiles: [BigFile] = []
    private var topThreshold: Int64 = 0
    private var deniedPaths: [String] = []
    private var rootDev: UInt32 = 0

    private let gate = NSCondition()
    private var queue: [(node: Int32, path: String)] = []
    private var busy = 0
    private var finished = false
    private var cancelled = false

    init(options: Options = Options()) {
        self.options = options
    }

    /// Stop as soon as every worker has finished the directory it is reading.
    /// What was measured is kept and reported as partial; nothing is patched.
    func cancel() {
        gate.lock()
        cancelled = true
        queue.removeAll()
        gate.broadcast()
        gate.unlock()
    }

    func scan(root rawPath: String) -> ScanResult {
        let started = Date()
        cad_set_io_policies()

        let rootPath = (rawPath as NSString).standardizingPath
        let rootNode = tree.addNode(name: rootPath, parent: -1)
        rootDev = deviceOf(path: rootPath)
        tree.own[Int(rootNode)] = rootDirectoryOwnSize(rootPath)

        queue.append((rootNode, rootPath))

        let workers = (0..<options.threads).map { index -> Thread in
            let thread = Thread { [weak self] in self?.workerLoop() }
            thread.name = "cadastre.walker.\(index)"
            thread.stackSize = 1 << 20
            return thread
        }
        workers.forEach { $0.start() }

        gate.lock()
        while !finished { gate.wait() }
        gate.unlock()

        tree.rollUp()
        let settlement = families.settle(tree: tree)
        applyRetained(settlement)

        stats.elapsed = Date().timeIntervalSince(started)
        stats.cancelled = cancelled
        stats.clonedInodes = families.clones.reduce(0) { $0 + $1.value.members.count }
        stats.hardLinkedInodes = families.inodes.values.filter { $0.nlink > 1 }.count

        topFiles.sort { $0.sizes.attributed > $1.sizes.attributed }
        if topFiles.count > options.topCount { topFiles.removeLast(topFiles.count - options.topCount) }

        return ScanResult(tree: tree, families: families, files: options.keepFiles ? files : nil,
                          root: rootNode, stats: stats, topFiles: topFiles,
                          settlement: settlement, deniedPaths: deniedPaths, rootDevice: rootDev)
    }

    // MARK: - Worker

    private func workerLoop() {
        let scratchBytes = 64 << 10
        // cad_bulk clamps its reply buffer so the kernel can never return more
        // entries than fit here, so this capacity is a hard guarantee.
        let capacity = scratchBytes / 32
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: scratchBytes, alignment: 16)
        let entries = UnsafeMutablePointer<cad_entry>.allocate(capacity: capacity)
        defer { scratch.deallocate(); entries.deallocate() }

        while true {
            gate.lock()
            while queue.isEmpty && busy > 0 { gate.wait() }
            if queue.isEmpty {
                finished = true
                gate.broadcast()
                gate.unlock()
                return
            }
            let job = queue.removeLast()
            // Snapshot the cutoff while the lock is held; workers must not
            // read it concurrently with commit() writing it.
            let cutoff = topThreshold
            busy += 1
            gate.unlock()

            let batch = readDirectory(node: job.node, path: job.path, cutoff: cutoff,
                                      scratch: scratch, scratchBytes: scratchBytes,
                                      entries: entries, capacity: capacity)

            gate.lock()
            commit(batch, parentPath: job.path)
            busy -= 1
            options.progress?(stats.directories, queue.count)
            gate.broadcast()
            gate.unlock()
        }
    }

    // MARK: - One directory

    private struct Subdirectory {
        var name: String
        var own: Sizes
        var skip: SkipReason?
    }

    private struct Batch {
        var node: Int32
        var own = Sizes()
        var fileCount: Int32 = 0
        var subdirectories: [Subdirectory] = []
        var files: [(name: String, sizes: Sizes, flags: FileTable.Flags)] = []
        var families = Families()
        var bigFiles: [BigFile] = []
        var stats = ScanStats()
        var denied = false
        var unreadable = false
    }

    private func readDirectory(node: Int32, path: String, cutoff: Int64,
                               scratch: UnsafeMutableRawPointer, scratchBytes: Int,
                               entries: UnsafeMutablePointer<cad_entry>, capacity: Int) -> Batch {
        var batch = Batch(node: node)

        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_DIRECTORY)
        guard fd >= 0 else {
            batch.denied = (errno == EACCES || errno == EPERM)
            batch.unreadable = !batch.denied
            if batch.denied { batch.stats.deniedDirectories = 1 } else { batch.stats.entryErrors = 1 }
            return batch
        }
        defer { close(fd) }

        batch.stats.directories = 1

        while true {
            let n = cad_bulk(fd, scratch, scratchBytes, entries, Int32(capacity))
            if n <= 0 {
                if n < 0 { batch.stats.entryErrors += 1 }
                break
            }
            for i in 0..<Int(n) {
                consume(&entries[i], into: &batch, parentPath: path, cutoff: cutoff)
            }
        }
        return batch
    }

    private func consume(_ entry: inout cad_entry, into batch: inout Batch,
                         parentPath: String, cutoff: Int64) {
        if entry.err != 0 {
            batch.stats.entryErrors += 1
            return
        }

        let onForeignVolume = (entry.valid & CAD_V_DEV) != 0 && entry.dev != rootDev
        let name = entryName(&entry)

        if entry.objtype == CAD_VDIR {
            let isMountPoint = (entry.mountstatus & UInt32(DIR_MNTSTATUS_MNTPOINT)) != 0
            // A foreign device id here means either a real mount or the far
            // side of a firmlink — /Users seen from the sealed system volume,
            // for instance. Descending would double-count the data volume.
            if (isMountPoint || onForeignVolume) && !options.crossMounts {
                batch.stats.crossedMounts = 1
                batch.subdirectories.append(Subdirectory(name: name, own: Sizes(), skip: .otherVolume))
                return
            }
            var own = Sizes()
            own.allocated = entry.allocated
            own.logical = entry.logical
            own.attributed = entry.allocated
            own.exclusive = entry.allocated
            own.retained = entry.allocated
            batch.subdirectories.append(Subdirectory(name: name, own: own, skip: nil))
            return
        }

        if onForeignVolume && !options.crossMounts { return }

        let nlink = max(entry.nlink, 1)
        let refcount = (entry.valid & CAD_V_REFCNT) != 0 ? max(entry.clone_refcnt, 1) : 1
        let allocated = entry.allocated
        // On a filesystem that cannot report exclusive bytes, every block is
        // treated as exclusive, which degrades gracefully to du's model.
        let inodeExclusive = (entry.valid & CAD_V_PRIVATE) != 0
            ? min(entry.private_size, allocated) : allocated
        let inodeShared = max(0, allocated - inodeExclusive)

        // A file's fair share: everything it owns outright, plus an equal cut
        // of what it shares. Summed over a volume this lands on the volume's
        // real occupancy, which no other per-file number does.
        let attributedPerInode = inodeExclusive + inodeShared / Int64(refcount)

        var sizes = Sizes()
        sizes.logical = entry.logical / Int64(nlink)
        sizes.allocated = allocated / Int64(nlink)
        sizes.attributed = attributedPerInode / Int64(nlink)
        sizes.exclusive = inodeExclusive / Int64(nlink)
        // Plain files retain exactly what they allocate. Shared ones are
        // settled later, once we know whether the whole family is in scope.
        sizes.retained = (nlink == 1 && refcount == 1) ? allocated : 0

        batch.own += sizes
        batch.fileCount += 1
        batch.stats.files += 1

        if nlink > 1 || refcount > 1 {
            batch.families.note(fileID: entry.fileid, nlink: nlink,
                                exclusive: inodeExclusive, shared: inodeShared,
                                cloneID: entry.cloneid, refcount: refcount,
                                node: batch.node)
        }

        let dataless = (entry.flags & UInt32(SF_DATALESS)) != 0
        let compressed = (entry.flags & UInt32(UF_COMPRESSED)) != 0
        if dataless {
            batch.stats.datalessFiles += 1
            batch.stats.datalessLogicalBytes += entry.logical
        } else if compressed {
            batch.stats.compressedFiles += 1
            batch.stats.compressedSaved += max(0, entry.logical - allocated)
        } else if entry.logical > allocated {
            batch.stats.sparseSaved += entry.logical - allocated
        }

        if options.keepFiles {
            var fileFlags: FileTable.Flags = []
            if dataless { fileFlags.insert(.dataless) }
            if compressed { fileFlags.insert(.compressed) }
            if refcount > 1 { fileFlags.insert(.cloned) }
            if nlink > 1 { fileFlags.insert(.hardLinked) }
            if entry.objtype == CAD_VLNK { fileFlags.insert(.symlink) }
            batch.files.append((name, sizes, fileFlags))
        }

        if sizes.attributed >= cutoff {
            batch.bigFiles.append(BigFile(path: parentPath == "/" ? "/" + name : parentPath + "/" + name, sizes: sizes,
                                          nlink: nlink, cloneRefcount: refcount,
                                          dataless: dataless, compressed: compressed))
        }
    }

    // MARK: - Commit (gate held)

    private func commit(_ batch: Batch, parentPath: String) {
        let node = Int(batch.node)
        tree.own[node] += batch.own
        tree.fileCount[node] += batch.fileCount
        if batch.denied {
            tree.skipped[node] = .denied
            if deniedPaths.count < 64 { deniedPaths.append(parentPath) }
        } else if batch.unreadable {
            tree.skipped[node] = .ioError
        }

        for sub in batch.subdirectories {
            let child = tree.addNode(name: sub.name, parent: batch.node)
            tree.own[Int(child)] = sub.own
            if let reason = sub.skip {
                tree.skipped[Int(child)] = reason
            } else if !cancelled {
                queue.append((child, parentPath == "/" ? "/" + sub.name : parentPath + "/" + sub.name))
            }
        }

        for file in batch.files {
            files.append(name: file.name, parent: batch.node, sizes: file.sizes, flags: file.flags)
        }

        families.merge(batch.families, tree: tree)

        stats.directories += batch.stats.directories
        stats.files += batch.stats.files
        stats.deniedDirectories += batch.stats.deniedDirectories
        stats.entryErrors += batch.stats.entryErrors
        stats.crossedMounts += batch.stats.crossedMounts
        stats.datalessFiles += batch.stats.datalessFiles
        stats.datalessLogicalBytes += batch.stats.datalessLogicalBytes
        stats.compressedFiles += batch.stats.compressedFiles
        stats.compressedSaved += batch.stats.compressedSaved
        stats.sparseSaved += batch.stats.sparseSaved

        topFiles.append(contentsOf: batch.bigFiles)
        if topFiles.count > options.topCount * 8 {
            topFiles.sort { $0.sizes.attributed > $1.sizes.attributed }
            topFiles.removeLast(topFiles.count - options.topCount)
            topThreshold = topFiles.last?.sizes.attributed ?? 0
        }
    }

    private func applyRetained(_ settlement: Families.Settlement) {
        for i in 0..<tree.count { tree.plainBytes[i] = tree.own[i].retained }
        guard !settlement.retainedAt.isEmpty else { return }
        for (node, bytes) in settlement.retainedAt where node >= 0 {
            tree.own[Int(node)].retained += bytes
        }
        // Retained is the one figure the first roll-up could not know, so it
        // gets a pass of its own now that every family has been settled.
        for i in 0..<tree.count { tree.total[i].retained = tree.own[i].retained }
        for i in stride(from: tree.count - 1, through: 1, by: -1) {
            let p = Int(tree.parent[i])
            if p >= 0 { tree.total[p].retained += tree.total[i].retained }
        }
    }

    // MARK: - Helpers

    private func rootDirectoryOwnSize(_ path: String) -> Sizes {
        var sizes = Sizes()
        var statInfo = stat()
        if lstat(path, &statInfo) == 0 {
            sizes.allocated = Int64(statInfo.st_blocks) * 512
            sizes.logical = Int64(statInfo.st_size)
            sizes.attributed = sizes.allocated
            sizes.exclusive = sizes.allocated
            sizes.retained = sizes.allocated
        }
        return sizes
    }

    private func deviceOf(path: String) -> UInt32 {
        var device: UInt32 = 0
        if cad_real_device(path, &device) == 0 { return device }
        var statInfo = stat()
        guard lstat(path, &statInfo) == 0 else { return 0 }
        return UInt32(bitPattern: statInfo.st_dev)
    }
}

@inline(__always)
private func entryName(_ entry: inout cad_entry) -> String {
    withUnsafeBytes(of: &entry.name) { raw in
        String(decoding: raw.prefix(Int(entry.name_len)), as: UTF8.self)
    }
}
