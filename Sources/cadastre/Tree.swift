import Foundation

/// Cadastre keeps five numbers per node instead of one, because on APFS
/// "how big is it" and "what do I get back if I delete it" are different
/// questions with different answers.
struct Sizes {
    /// Sum of data and resource forks, uncompressed. What Finder shows.
    var logical: Int64 = 0
    /// Blocks actually on disk. Counts a cloned block once per file, so it
    /// over-states the total on any volume with clones.
    var allocated: Int64 = 0
    /// Each file's fair share of the blocks it shares with its clones and
    /// hard links. The only one of the five that sums to the volume's real
    /// occupancy, which is why the treemap uses it by default.
    var attributed: Int64 = 0
    /// Blocks shared with nothing: exactly what deleting this one entry
    /// frees, and nothing more.
    var exclusive: Int64 = 0
    /// What deleting this entire subtree frees, including blocks shared
    /// between files that both live inside it. Computed in a second pass.
    var retained: Int64 = 0

    static func += (lhs: inout Sizes, rhs: Sizes) {
        lhs.logical += rhs.logical
        lhs.allocated += rhs.allocated
        lhs.attributed += rhs.attributed
        lhs.exclusive += rhs.exclusive
        lhs.retained += rhs.retained
    }
}

enum Metric: String, CaseIterable {
    case logical, allocated, attributed, exclusive, retained

    /// The raw values are the command-line spellings and stay as they are; a
    /// menu showing "attributed" next to "exclusive" explains nothing to
    /// anyone who has not read the source.
    var title: String {
        switch self {
        case .logical: return tr("Logical size")
        case .allocated: return tr("Allocated blocks")
        case .attributed: return tr("Real footprint")
        case .exclusive: return tr("Exclusive to entry")
        case .retained: return tr("Reclaimable")
        }
    }

    /// Shorter, for table headers and the inspector.
    var shortTitle: String {
        switch self {
        case .logical: return tr("logical")
        case .allocated: return tr("allocated")
        case .attributed: return tr("real")
        case .exclusive: return tr("exclusive")
        case .retained: return tr("reclaimable")
        }
    }

    var explanation: String {
        switch self {
        case .logical:
            return tr("sum of the forks, uncompressed — what the Finder shows")
        case .allocated:
            return tr("what is on disk, a clone counted in every file — like du")
        case .attributed:
            return tr("fair share of shared blocks — the only measure whose sum is right")
        case .exclusive:
            return tr("what deleting this one entry frees")
        case .retained:
            return tr("what deleting the whole subtree frees")
        }
    }

    func value(_ s: Sizes) -> Int64 {
        switch self {
        case .logical: return s.logical
        case .allocated: return s.allocated
        case .attributed: return s.attributed
        case .exclusive: return s.exclusive
        case .retained: return s.retained
        }
    }
}

/// Why a directory was not descended into.
enum SkipReason: UInt8 {
    case denied         // EACCES/EPERM — very often a missing Full Disk Access
    case otherVolume    // a mount point, or the far side of a firmlink
    case ioError
}

struct BigFile {
    var path: String
    var sizes: Sizes
    var nlink: UInt32
    var cloneRefcount: UInt32
    var dataless: Bool
    var compressed: Bool
}

/// Directory tree as a struct of arrays. Only directories get a node; files
/// are folded into their parent, with the largest kept aside for the report.
/// A full boot-volume scan is a few hundred thousand directories, so the tree
/// stays in tens of megabytes even when the file count runs into millions.
final class Tree {
    var name: [String] = []
    var parent: [Int32] = []
    var depth: [Int32] = []
    var children: [[Int32]] = []

    /// Entries held directly by this directory: its own metadata blocks plus
    /// every non-directory child.
    var own: [Sizes] = []
    /// `own` rolled up over the subtree. Filled by `rollUp()`.
    var total: [Sizes] = []

    var fileCount: [Int32] = []
    var skipped: [SkipReason?] = []
    /// Bytes held by this directory that belong to nothing else: its own
    /// metadata plus every file with a single link and no clone. Snapshotted
    /// before clone families are settled on top of `own.retained`.
    var plainBytes: [Int64] = []

    @discardableResult
    func addNode(name n: String, parent p: Int32) -> Int32 {
        let index = Int32(name.count)
        name.append(n)
        parent.append(p)
        depth.append(p < 0 ? 0 : depth[Int(p)] + 1)
        children.append([])
        own.append(Sizes())
        total.append(Sizes())
        fileCount.append(0)
        skipped.append(nil)
        plainBytes.append(0)
        if p >= 0 { children[Int(p)].append(index) }
        return index
    }

    var count: Int { name.count }

    func path(of node: Int32) -> String {
        var parts: [String] = []
        var i = node
        while i >= 0 {
            parts.append(name[Int(i)])
            i = parent[Int(i)]
        }
        // The root node carries the full scan path, so joining from there down
        // yields an absolute path without special-casing "/".
        let root = parts.removeLast()
        if parts.isEmpty { return root }
        let tail = parts.reversed().joined(separator: "/")
        return root.hasSuffix("/") ? root + tail : root + "/" + tail
    }

    /// Lowest common ancestor, used to decide which directory a clone family
    /// or a set of hard links is wholly contained in.
    func lca(_ a: Int32, _ b: Int32) -> Int32 {
        if a < 0 { return b }
        if b < 0 { return a }
        var x = a, y = b
        while depth[Int(x)] > depth[Int(y)] { x = parent[Int(x)] }
        while depth[Int(y)] > depth[Int(x)] { y = parent[Int(y)] }
        while x != y { x = parent[Int(x)]; y = parent[Int(y)] }
        return x
    }

    /// Children are visited before parents, so a single reverse pass over the
    /// node array is enough: nodes are created in breadth-first-ish order and
    /// a child's index always exceeds its parent's.
    func rollUp() {
        total = own
        for i in stride(from: count - 1, through: 1, by: -1) {
            let p = Int(parent[i])
            if p >= 0 { total[p] += total[i] }
        }
        for i in stride(from: count - 1, through: 1, by: -1) {
            let p = Int(parent[i])
            if p >= 0 { fileCount[p] += fileCount[i] }
        }
    }
}

/// Per-file records, kept only when someone will read them: the treemap wants
/// a rectangle per file, and a diff wants to name what appeared and what grew.
///
/// Struct of arrays, and no children lists — a directory's files are recovered
/// by grouping on `parent`. A million files costs roughly eighty megabytes,
/// which is why this is opt-in rather than always on.
final class FileTable {
    struct Flags: OptionSet {
        let rawValue: UInt16
        static let dataless   = Flags(rawValue: 1 << 0)
        static let compressed = Flags(rawValue: 1 << 1)
        static let cloned     = Flags(rawValue: 1 << 2)
        static let hardLinked = Flags(rawValue: 1 << 3)
        static let symlink    = Flags(rawValue: 1 << 4)
    }

    var name: [String] = []
    var parent: [Int32] = []
    var sizes: [Sizes] = []
    var flags: [Flags] = []

    var count: Int { name.count }

    func append(name n: String, parent p: Int32, sizes s: Sizes, flags f: Flags) {
        name.append(n)
        parent.append(p)
        sizes.append(s)
        flags.append(f)
    }

    func reserve(_ capacity: Int) {
        name.reserveCapacity(capacity)
        parent.reserveCapacity(capacity)
        sizes.reserveCapacity(capacity)
        flags.reserveCapacity(capacity)
    }

    /// One bucket of file indices per directory node.
    func groupedByDirectory(directoryCount: Int) -> [[Int32]] {
        var buckets = [[Int32]](repeating: [], count: directoryCount)
        for i in 0..<count {
            let dir = Int(parent[i])
            if dir >= 0 && dir < directoryCount { buckets[dir].append(Int32(i)) }
        }
        return buckets
    }
}
