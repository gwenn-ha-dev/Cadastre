import Foundation

/// On-disk form of a scan.
///
/// A scan is worth keeping: it is the only way to answer "what grew since last
/// week", which is the question people actually have. JSON was tempting and is
/// the wrong shape — a few million nodes of it costs more to parse than the
/// scan costs to redo. This is a flat binary layout of fixed-width records
/// plus one name arena, so loading is a read and a pointer walk.
///
///     header
///     directory records   (fixed width, parent-before-child order)
///     file records        (fixed width)
///     name arena          (UTF-8, addressed by offset and length)
///
/// Only each node's *own* sizes are stored. Subtree totals are recomputed by
/// rolling up on load, which is fast and removes any chance of the two
/// disagreeing.
enum ScanIndex {
    static let magic: UInt32 = 0x43445354   // "CDST"
    static let version: UInt32 = 1

    struct Header {
        var version: UInt32
        var hasFiles: Bool
        var scannedAt: Date
        var rootPath: String
        var directoryCount: Int
        var fileCount: Int
    }

    struct Loaded {
        var header: Header
        var tree: Tree
        var files: FileTable?
        var stats: ScanStats
        var root: Int32 { 0 }
    }

    enum Failure: Error, CustomStringConvertible {
        case notAnIndex(String)
        case unsupportedVersion(UInt32)
        case truncated(String)

        var description: String {
            switch self {
            case .notAnIndex(let path): return tr("%@ is not a Cadastre index", path)
            case .unsupportedVersion(let v):
                return tr("index version %d, expected %d", v, ScanIndex.version)
            case .truncated(let path): return tr("truncated index: %@", path)
            }
        }
    }

    // MARK: - Write

    static func write(_ result: ScanResult, scannedAt: Date = Date(), to path: String) throws {
        let tree = result.tree
        let files = result.files

        var names = [UInt8]()
        names.reserveCapacity(tree.count * 16 + (files?.count ?? 0) * 16)
        var body = [UInt8]()
        body.reserveCapacity(tree.count * 64 + (files?.count ?? 0) * 56)

        func intern(_ text: String) -> (UInt32, UInt32) {
            let offset = UInt32(names.count)
            names.append(contentsOf: text.utf8)
            return (offset, UInt32(names.count) - offset)
        }

        for i in 0..<tree.count {
            let (offset, length) = intern(tree.name[i])
            body.append(tree.parent[i])
            body.append(tree.depth[i])
            body.append(offset)
            body.append(length)
            body.append(sizes: tree.own[i])
            body.append(tree.fileCount[i])
            body.append(UInt32(tree.skipped[i].map { $0.rawValue } ?? 0xFF))
        }

        if let files {
            for i in 0..<files.count {
                let (offset, length) = intern(files.name[i])
                body.append(files.parent[i])
                body.append(offset)
                body.append(length)
                body.append(UInt32(files.flags[i].rawValue))
                body.append(sizes: files.sizes[i])
            }
        }

        var out = [UInt8]()
        out.reserveCapacity(body.count + names.count + 256)
        out.append(magic)
        out.append(version)
        out.append(UInt32(files == nil ? 0 : 1))
        out.append(scannedAt.timeIntervalSince1970)
        out.append(UInt32(tree.count))
        out.append(UInt32(files?.count ?? 0))
        out.append(UInt64(names.count))
        for value in result.stats.serialized { out.append(value) }
        let rootPath = tree.name.first ?? ""
        out.append(UInt32(rootPath.utf8.count))
        out.append(contentsOf: rootPath.utf8)
        out.append(contentsOf: body)
        out.append(contentsOf: names)

        try Data(out).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    // MARK: - Read

    static func read(_ path: String) throws -> Loaded {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        return try data.withUnsafeBytes { raw -> Loaded in
            var reader = Reader(raw: raw, path: path)

            guard try reader.u32() == magic else { throw Failure.notAnIndex(path) }
            let fileVersion = try reader.u32()
            guard fileVersion == version else { throw Failure.unsupportedVersion(fileVersion) }
            let hasFiles = try reader.u32() == 1
            let scannedAt = Date(timeIntervalSince1970: try reader.f64())
            let directoryCount = Int(try reader.u32())
            let fileCount = Int(try reader.u32())
            let nameBytes = Int(try reader.u64())
            var statsValues = [Int64]()
            for _ in 0..<ScanStats.fieldCount { statsValues.append(try reader.i64()) }
            let rootPathLength = Int(try reader.u32())
            let rootPath = try reader.string(rootPathLength)

            let namesStart = reader.offset + directoryCount * 64 + fileCount * 56
            guard namesStart + nameBytes <= raw.count else { throw Failure.truncated(path) }
            let arena = UnsafeRawBufferPointer(rebasing: raw[namesStart..<(namesStart + nameBytes)])

            func name(at offset: UInt32, length: UInt32) throws -> String {
                let start = Int(offset), end = start + Int(length)
                guard end <= arena.count else { throw Failure.truncated(path) }
                return String(decoding: UnsafeRawBufferPointer(rebasing: arena[start..<end]), as: UTF8.self)
            }

            let tree = Tree()
            tree.name.reserveCapacity(directoryCount)
            for _ in 0..<directoryCount {
                let parent: Int32 = try reader.i32()
                let depth: Int32 = try reader.i32()
                let nameOffset = try reader.u32()
                let nameLength = try reader.u32()
                let own = try reader.sizes()
                let ownFileCount: Int32 = try reader.i32()
                let skippedRaw = try reader.u32()

                tree.name.append(try name(at: nameOffset, length: nameLength))
                tree.parent.append(parent)
                tree.depth.append(depth)
                tree.children.append([])
                tree.own.append(own)
                tree.total.append(Sizes())
                tree.fileCount.append(ownFileCount)
                tree.skipped.append(skippedRaw == 0xFF ? nil : SkipReason(rawValue: UInt8(skippedRaw)))
                tree.plainBytes.append(own.retained)
            }
            for child in 1..<max(tree.count, 1) {
                let parent = Int(tree.parent[child])
                if parent >= 0 { tree.children[parent].append(Int32(child)) }
            }
            tree.rollUp()

            var files: FileTable? = nil
            if hasFiles {
                let table = FileTable()
                table.reserve(fileCount)
                for _ in 0..<fileCount {
                    let parent: Int32 = try reader.i32()
                    let nameOffset = try reader.u32()
                    let nameLength = try reader.u32()
                    let flags = FileTable.Flags(rawValue: UInt16(truncatingIfNeeded: try reader.u32()))
                    let sizes = try reader.sizes()
                    table.append(name: try name(at: nameOffset, length: nameLength),
                                 parent: parent, sizes: sizes, flags: flags)
                }
                files = table
            }

            let header = Header(version: fileVersion, hasFiles: hasFiles, scannedAt: scannedAt,
                                rootPath: rootPath, directoryCount: directoryCount, fileCount: fileCount)
            return Loaded(header: header, tree: tree, files: files,
                          stats: ScanStats(serialized: statsValues))
        }
    }

    private struct Reader {
        let raw: UnsafeRawBufferPointer
        let path: String
        var offset = 0

        mutating func take(_ count: Int) throws -> Int {
            guard offset + count <= raw.count else { throw Failure.truncated(path) }
            defer { offset += count }
            return offset
        }
        mutating func u32() throws -> UInt32 { raw.loadUnaligned(fromByteOffset: try take(4), as: UInt32.self) }
        mutating func i32() throws -> Int32 { raw.loadUnaligned(fromByteOffset: try take(4), as: Int32.self) }
        mutating func u64() throws -> UInt64 { raw.loadUnaligned(fromByteOffset: try take(8), as: UInt64.self) }
        mutating func i64() throws -> Int64 { raw.loadUnaligned(fromByteOffset: try take(8), as: Int64.self) }
        mutating func f64() throws -> Double { raw.loadUnaligned(fromByteOffset: try take(8), as: Double.self) }
        mutating func string(_ length: Int) throws -> String {
            let start = try take(length)
            return String(decoding: UnsafeRawBufferPointer(rebasing: raw[start..<(start + length)]), as: UTF8.self)
        }
        mutating func sizes() throws -> Sizes {
            Sizes(logical: try i64(), allocated: try i64(), attributed: try i64(),
                  exclusive: try i64(), retained: try i64())
        }
    }
}

// MARK: - Fixed-width appends

private extension Array where Element == UInt8 {
    mutating func append<T>(_ value: T) {
        Swift.withUnsafeBytes(of: value) { append(contentsOf: $0) }
    }
    mutating func append(sizes: Sizes) {
        append(sizes.logical)
        append(sizes.allocated)
        append(sizes.attributed)
        append(sizes.exclusive)
        append(sizes.retained)
    }
}

extension ScanStats {
    static let fieldCount = 12

    var serialized: [Int64] {
        [Int64(directories), Int64(files), Int64(deniedDirectories), Int64(entryErrors),
         Int64(crossedMounts), Int64(datalessFiles), datalessLogicalBytes,
         Int64(compressedFiles), compressedSaved, sparseSaved,
         Int64(clonedInodes), Int64(hardLinkedInodes)]
    }

    init(serialized values: [Int64]) {
        self.init()
        guard values.count >= ScanStats.fieldCount else { return }
        directories = Int(values[0])
        files = Int(values[1])
        deniedDirectories = Int(values[2])
        entryErrors = Int(values[3])
        crossedMounts = Int(values[4])
        datalessFiles = Int(values[5])
        datalessLogicalBytes = values[6]
        compressedFiles = Int(values[7])
        compressedSaved = values[8]
        sparseSaved = values[9]
        clonedInodes = Int(values[10])
        hardLinkedInodes = Int(values[11])
    }
}

/// Where `--save auto` puts things and where `--since last` looks.
///
/// Keeping a small history locally is what turns a one-off measurement into a
/// usable habit: scan today, and next week the diff is one flag away.
enum SnapshotStore {
    /// `CADASTRE_HOME` moves the marker history elsewhere — used by the test
    /// suite so checking the feature does not litter the real one.
    static var directory: String {
        if let override = ProcessInfo.processInfo.environment["CADASTRE_HOME"], !override.isEmpty {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Cadastre").path
    }

    /// Scan paths become filenames, reversibly enough to group by target.
    private static func slug(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        let cleaned = trimmed.map { $0 == "/" ? "_" : $0 }
        return String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            .replacingOccurrences(of: " ", with: "-")
    }

    private static var stamp: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }

    static func newPath(for scanPath: String, at date: Date = Date()) throws -> String {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let name = "\(slug(scanPath))@\(stamp.string(from: date)).cdst"
        return (directory as NSString).appendingPathComponent(name)
    }

    /// Saved scans of one path, newest first.
    static func history(for scanPath: String? = nil) -> [(path: String, date: Date)] {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        let prefix = scanPath.map { slug($0) + "@" }
        return entries
            .filter { $0.hasSuffix(".cdst") && (prefix == nil || $0.hasPrefix(prefix!)) }
            .map { (directory as NSString).appendingPathComponent($0) }
            .compactMap { path in
                // The date in the name is when the scan ran; the file's own
                // mtime is when it happened to be written, which can be much
                // later. Using the wrong one makes a marker look like a
                // different moment than the state it holds — and lets a
                // session offer its own marker as something to compare against.
                let name = (path as NSString).deletingPathExtension as NSString
                let encoded = name.components(separatedBy: "@").last ?? ""
                if let date = stamp.date(from: encoded) { return (path, date) }
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                return (path, attributes?[.modificationDate] as? Date ?? .distantPast)
            }
            .sorted { $0.date > $1.date }
    }

    static func mostRecent(for scanPath: String) -> String? {
        history(for: scanPath).first?.path
    }
}
