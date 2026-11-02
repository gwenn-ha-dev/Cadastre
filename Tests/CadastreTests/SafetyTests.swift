import XCTest
@testable import cadastre

/// The guards in front of the Trash, and the walker and index on a real
/// folder. Built under /tmp rather than the user's temporary directory: that
/// one lives in /private/var/folders, which the guards rightly refuse.
final class SafetyTests: XCTestCase {
    private var base = ""

    override func setUpWithError() throws {
        base = "/tmp/cadastre-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    private func folder(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: base + "/" + relative, withIntermediateDirectories: true)
    }

    private func file(_ relative: String, bytes: Int = 4) throws {
        let path = base + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(count: bytes).write(to: URL(fileURLWithPath: path))
    }

    private var npm: Reclaim.Rule { Reclaim.catalogue.first { $0.id == "node_modules" }! }

    // MARK: - Guards

    func testProtectedAreasResistSpellingAndPrivatePrefix() {
        XCTAssertTrue(Reclaim.isProtected("/var/folders/xy/T/thing"), "/var is /private/var")
        XCTAssertTrue(Reclaim.isProtected("/private/var/db/x"))
        XCTAssertTrue(Reclaim.isProtected("/var/db/x"))
        XCTAssertTrue(Reclaim.isProtected("/applications/Safari.app"), "the volume is case-insensitive")
        XCTAssertTrue(Reclaim.isProtected("/System/Volumes/Data/Applications/X.app"))
        XCTAssertFalse(Reclaim.isProtected("/tmp/project"))
        XCTAssertFalse(Reclaim.isProtected("/Users/x/Library/Caches"))
    }

    func testNodeModulesNeedsALockfile() throws {
        try file("web/package.json")
        try folder("web/node_modules/left-pad")
        XCTAssertNotNil(Reclaim.verify(base + "/web/node_modules", rule: npm),
                        "a package.json alone is also what an installed package carries")
        try file("web/package-lock.json")
        XCTAssertNil(Reclaim.verify(base + "/web/node_modules", rule: npm))
    }

    func testNothingInsideAnInstalledPackageOrABundle() throws {
        try file("web/package-lock.json")
        try file("web/node_modules/tool/package-lock.json")
        try folder("web/node_modules/tool/node_modules")
        XCTAssertEqual(Reclaim.verify(base + "/web/node_modules/tool/node_modules", rule: npm),
                       tr("is inside an installed package"))

        try file("Editor.app/Contents/Resources/app/package-lock.json")
        try folder("Editor.app/Contents/Resources/app/node_modules")
        XCTAssertEqual(Reclaim.verify(base + "/Editor.app/Contents/Resources/app/node_modules", rule: npm),
                       tr("is inside an application bundle"))
    }

    func testAPathThroughASymbolicLinkIsRefused() throws {
        try file("real/web/package-lock.json")
        try folder("real/web/node_modules")
        try FileManager.default.createSymbolicLink(atPath: base + "/alias", withDestinationPath: base + "/real")
        XCTAssertNil(Reclaim.verify(base + "/real/web/node_modules", rule: npm))
        XCTAssertEqual(Reclaim.verify(base + "/alias/web/node_modules", rule: npm),
                       tr("is reached through a symbolic link"))
    }

    // MARK: - Walker

    func testARootThatIsALinkIsFollowed() throws {
        try file("real/a", bytes: 1 << 20)
        try FileManager.default.createSymbolicLink(atPath: base + "/alias", withDestinationPath: base + "/real")
        let result = Walker().scan(root: base + "/alias")
        XCTAssertEqual(result.stats.files, 1)
        XCTAssertGreaterThanOrEqual(result.tree.total[0].logical, 1 << 20)
    }

    func testAVeryLongFolderNameKeepsItsContents() throws {
        // 200 CJK characters: 600 bytes of UTF-8, legal on APFS.
        let name = String(repeating: "漢", count: 200)
        try file(name + "/a", bytes: 1 << 20)
        let result = Walker().scan(root: base)
        XCTAssertEqual(result.stats.files, 1)
        XCTAssertEqual(result.stats.entryErrors, 0)
    }

    // MARK: - Index

    func testAnInterruptedScanSaysSoAfterARoundTrip() throws {
        try file("a", bytes: 4096)
        var result = Walker().scan(root: base)
        result.stats.cancelled = true
        let index = base + "/scan.cdst"
        try ScanIndex.write(result, to: index)
        XCTAssertTrue(try ScanIndex.read(index).stats.cancelled)
        XCTAssertEqual(try ScanIndex.rootPath(of: index), result.tree.name[0])
    }

    func testACorruptParentIsRefusedNotTrusted() throws {
        try folder("sub")
        let result = Walker().scan(root: base)
        let index = base + "/scan.cdst"
        try ScanIndex.write(result, to: index)
        var bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: index)))
        // Header: magic, version, files flag, date, two counts, arena size,
        // the statistics, then the root path; then 64-byte directory records.
        let rootLength = result.tree.name[0].utf8.count
        let header = 4 + 4 + 4 + 8 + 4 + 4 + 8 + 8 * ScanStats.fieldCount + 4 + rootLength
        let secondParent = header + 64
        withUnsafeBytes(of: Int32(99)) { bytes.replaceSubrange(secondParent..<(secondParent + 4), with: $0) }
        try Data(bytes).write(to: URL(fileURLWithPath: index))
        XCTAssertThrowsError(try ScanIndex.read(index))
    }

    func testHistoryDoesNotConfuseFoldersWithTheSameSlug() throws {
        try folder("a/b_c")
        try folder("a_b/c")
        setenv("CADASTRE_HOME", base + "/history", 1)
        defer { unsetenv("CADASTRE_HOME") }
        let scanned = base + "/a/b_c"
        try ScanIndex.write(Walker().scan(root: scanned), to: SnapshotStore.newPath(for: scanned))
        XCTAssertEqual(SnapshotStore.history(for: scanned).count, 1)
        XCTAssertEqual(SnapshotStore.history(for: base + "/a_b/c").count, 0,
                       "same file-name slug, different folder")
    }
}
