import XCTest
@testable import cadastre
import CadastreStrings

/// A small tree built by hand: the walker's commit path, without the disk.
private struct Fixture {
    let tree = Tree()
    var families = Families()

    init() { tree.addNode(name: "/root", parent: -1) }

    @discardableResult
    mutating func directory(_ name: String, under parent: Int32) -> Int32 {
        tree.addNode(name: name, parent: parent)
    }

    /// A plain file: every byte is its own.
    mutating func plain(_ bytes: Int64, in node: Int32) {
        var sizes = Sizes()
        sizes.logical = bytes; sizes.allocated = bytes; sizes.attributed = bytes
        sizes.exclusive = bytes; sizes.retained = bytes
        tree.own[Int(node)] += sizes
        tree.fileCount[Int(node)] += 1
    }

    /// One member of a clone family: `shared` bytes held with `refcount - 1`
    /// other inodes, credited to nobody until the family is settled.
    mutating func clone(id: UInt64, fileID: UInt64, shared: Int64, refcount: UInt32, in node: Int32) {
        var sizes = Sizes()
        sizes.logical = shared; sizes.allocated = shared
        sizes.attributed = shared / Int64(refcount)
        tree.own[Int(node)] += sizes
        tree.fileCount[Int(node)] += 1
        var local = Families()
        local.note(fileID: fileID, nlink: 1, exclusive: 0, shared: shared, cloneID: id, refcount: refcount, node: node)
        families.merge(local, tree: tree)
    }

    /// One name of a hard-linked inode with `nlink` names in total.
    mutating func link(fileID: UInt64, bytes: Int64, nlink: UInt32, in node: Int32) {
        var sizes = Sizes()
        sizes.logical = bytes / Int64(nlink); sizes.allocated = bytes / Int64(nlink)
        sizes.attributed = bytes / Int64(nlink); sizes.exclusive = bytes / Int64(nlink)
        tree.own[Int(node)] += sizes
        tree.fileCount[Int(node)] += 1
        var local = Families()
        local.note(fileID: fileID, nlink: nlink, exclusive: bytes, shared: 0, cloneID: 0, refcount: 1, node: node)
        families.merge(local, tree: tree)
    }

    /// What the walker does once the queue drains.
    func settle() -> (Tree, Families.Settlement) {
        tree.rollUp()
        let settlement = families.settle(tree: tree)
        for i in 0..<tree.count { tree.plainBytes[i] = tree.own[i].retained }
        for (node, bytes) in settlement.retainedAt where node >= 0 { tree.own[Int(node)].retained += bytes }
        for i in 0..<tree.count { tree.total[i].retained = tree.own[i].retained }
        for i in stride(from: tree.count - 1, through: 1, by: -1) {
            let p = Int(tree.parent[i])
            if p >= 0 { tree.total[p].retained += tree.total[i].retained }
        }
        return (tree, settlement)
    }
}

final class FamiliesTests: XCTestCase {
    func testCloneFamilyIsCreditedToItsLowestCommonAncestor() {
        var f = Fixture()
        let a = f.directory("a", under: 0)
        let b = f.directory("b", under: 0)
        let deep = f.directory("deep", under: a)
        f.clone(id: 7, fileID: 1, shared: 1000, refcount: 2, in: deep)
        f.clone(id: 7, fileID: 2, shared: 1000, refcount: 2, in: b)
        let (tree, settlement) = f.settle()

        XCTAssertEqual(settlement.retainedAt[0], 1000, "the family straddles a and b: only the root contains it whole")
        XCTAssertEqual(tree.total[Int(a)].retained, 0, "deleting a alone frees nothing")
        XCTAssertEqual(tree.total[Int(b)].retained, 0)
        XCTAssertEqual(tree.total[0].retained, 1000)
        XCTAssertEqual(tree.total[0].attributed, 1000, "attributed sums to the real occupancy")
        XCTAssertEqual(tree.total[0].allocated, 2000, "allocated counts the clone twice, like du")
    }

    func testIncompleteFamilyReachesOutsideTheScan() {
        var f = Fixture()
        let a = f.directory("a", under: 0)
        f.clone(id: 9, fileID: 1, shared: 500, refcount: 3, in: a)   // two members are elsewhere
        let (tree, settlement) = f.settle()
        XCTAssertEqual(settlement.reachesOutside, 500)
        XCTAssertEqual(settlement.straddlingFamilies, 1)
        XCTAssertEqual(tree.total[0].retained, 0)
    }

    func testHardLinksAreFreedOnlyWhenEveryNameGoes() {
        var f = Fixture()
        let a = f.directory("a", under: 0)
        let b = f.directory("b", under: 0)
        f.link(fileID: 42, bytes: 2000, nlink: 2, in: a)
        f.link(fileID: 42, bytes: 2000, nlink: 2, in: b)
        let (tree, _) = f.settle()

        func marked(_ nodes: [Int32]) -> [Bool] {
            var m = [Bool](repeating: false, count: tree.count)
            nodes.forEach { m[Int($0)] = true }
            return m
        }
        XCTAssertEqual(f.families.bytesFreed(deleting: marked([a]), plainBytes: tree.plainBytes), 0)
        XCTAssertEqual(f.families.bytesFreed(deleting: marked([a, b]), plainBytes: tree.plainBytes), 2000,
                       "the pnpm case: the set frees what its parts do not")
    }

    func testPlainFilesRollUp() {
        var f = Fixture()
        let a = f.directory("a", under: 0)
        let aa = f.directory("aa", under: a)
        f.plain(100, in: a)
        f.plain(250, in: aa)
        let (tree, _) = f.settle()
        XCTAssertEqual(tree.total[Int(a)].attributed, 350)
        XCTAssertEqual(tree.total[Int(a)].retained, 350)
        XCTAssertEqual(tree.fileCount[0], 2)
        XCTAssertEqual(tree.path(of: aa), "/root/a/aa")
    }
}

final class LayoutTests: XCTestCase {
    func testPackedAreasAreProportionalAndDisjoint() {
        let values: [Float] = [50, 20, 15, 10, 4, 1]
        let bounds = Rect(x: 0, y: 0, width: 400, height: 250)
        let rects = TreemapLayout.pack(values, in: bounds)
        XCTAssertEqual(rects.count, values.count)
        let total = values.reduce(0, +)
        for (rect, value) in zip(rects, values) {
            XCTAssertEqual(Double(rect.area / bounds.area), Double(value / total), accuracy: 1e-4)
            XCTAssertGreaterThanOrEqual(rect.x, -0.01); XCTAssertGreaterThanOrEqual(rect.y, -0.01)
            XCTAssertLessThanOrEqual(rect.x + rect.width, bounds.width + 0.01)
            XCTAssertLessThanOrEqual(rect.y + rect.height, bounds.height + 0.01)
        }
        for i in 0..<rects.count {
            for j in (i + 1)..<rects.count {
                let a = rects[i], b = rects[j]
                let overlap = a.x + 0.01 < b.x + b.width && b.x + 0.01 < a.x + a.width
                    && a.y + 0.01 < b.y + b.height && b.y + 0.01 < a.y + a.height
                XCTAssertFalse(overlap, "rectangles \(i) and \(j) overlap")
            }
        }
    }

    func testRootHasNoTitleBand() {
        let rect = Rect(x: 0, y: 0, width: 300, height: 200)
        XCTAssertEqual(TreemapLayout.childArea(of: rect, isRoot: true)?.height, 200)
        XCTAssertEqual(TreemapLayout.childArea(of: rect)?.height, 200 - 2 - TreemapLayout.defaultLabelBand)
    }
}

final class FormattingTests: XCTestCase {
    override func tearDown() { L10n.language = L10n.detect() }

    func testUnitsFollowTheLanguage() {
        L10n.language = .en
        XCTAssertEqual(humanBytes(6_360_000_000), "6.36\u{00A0}GB")
        XCTAssertEqual(humanBytes(999), "999\u{00A0}B")
        XCTAssertEqual(signedBytes(1_500_000), "+1.50\u{00A0}MB")
        L10n.language = .fr
        XCTAssertEqual(humanBytes(6_360_000_000), "6,36\u{00A0}Go")
        XCTAssertEqual(humanBytes(-16_400), "-16,4\u{00A0}ko")
        XCTAssertEqual(tr("Reclaimable"), "Récupérable")
        L10n.language = .en
        XCTAssertEqual(tr("Reclaimable"), "Reclaimable")
    }

    /// The catalogue is embedded in the binary; an empty or unreadable one
    /// would silently leave a French system in English.
    func testEmbeddedCatalogueHasEveryEntryInFrench() throws {
        struct Catalog: Decodable {
            struct Entry: Decodable { let localizations: [String: [String: [String: String]]]? }
            let sourceLanguage: String
            let strings: [String: Entry]
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: StringCatalog.data)
        XCTAssertEqual(catalog.sourceLanguage, "en")
        XCTAssertGreaterThan(catalog.strings.count, 300)
        let untranslated = catalog.strings.filter { $0.value.localizations?["fr"]?["stringUnit"]?["value"] == nil }
        XCTAssertEqual(untranslated.map(\.key), [])
    }

    func testGuardsSeeThroughTheDataVolume() {
        XCTAssertTrue(Reclaim.isProtected("/System/Library"))
        XCTAssertFalse(Reclaim.isProtected("/System/Volumes/Data/Users/x/Library/Caches"))
        XCTAssertFalse(Reclaim.isProtected("/usr/local/lib"))
        XCTAssertTrue(Reclaim.isProtected("/usr/lib"))
        XCTAssertFalse(Reclaim.isProtected("/opt/homebrew"))
        XCTAssertEqual(Reclaim.canonical("/System/Volumes/Data"), "/")
    }
}

final class DiffTests: XCTestCase {
    private func snapshot(_ build: (inout Fixture) -> Void) -> Snapshot {
        var f = Fixture()
        build(&f)
        let (tree, _) = f.settle()
        return Snapshot(scannedAt: Date(), tree: tree, files: nil, stats: ScanStats())
    }

    func testGrowthIsAttributedToTheFolderThatWrote() {
        let before = snapshot { f in
            let build = f.directory("build", under: 0); f.plain(1 << 20, in: build)
            let src = f.directory("src", under: 0); f.plain(1 << 20, in: src)
        }
        let after = snapshot { f in
            let build = f.directory("build", under: 0); f.plain(60 << 20, in: build)
            let src = f.directory("src", under: 0); f.plain(1 << 20, in: src)
            let fresh = f.directory("node_modules", under: 0); f.plain(20 << 20, in: fresh)
        }
        let diff = ScanDiff.compare(before, after, metric: .attributed)
        XCTAssertEqual(diff.delta, 79 << 20)
        let byPath = Dictionary(uniqueKeysWithValues: diff.directories.map { ($0.path, $0) })
        XCTAssertEqual(byPath["/root/build"]?.own, 59 << 20)
        XCTAssertEqual(byPath["/root/build"]?.status, .changed)
        XCTAssertEqual(byPath["/root/node_modules"]?.status, .added)
        XCTAssertNil(byPath["/root/src"], "an unchanged folder is not reported")
    }
}
