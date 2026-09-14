import XCTest
import GRDB
@testable import Catalog

final class FolderAccessTests: XCTestCase {
    nonisolated(unsafe) var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-folders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFolders(_ paths: [String]) throws {
        for path in paths {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
    }

    /// Hidden folders, catalog containers, packages, links and plain files
    /// are not subfolders; the rest come back in Finder's name order.
    func testSubfoldersSkipsWhatTheTreeMustNotShow() throws {
        let fm = FileManager.default
        try makeFolders(["Day 10", "Day 2", ".hidden", "_latent/xmp", "_rawhead", "Shots.photoslibrary", "Real"])
        try Data("x".utf8).write(to: root.appendingPathComponent("A.NEF"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("Link"), withDestinationURL: root.appendingPathComponent("Real"))

        let names = FolderAccess.subfolders(of: root).map(\.lastPathComponent)
        XCTAssertEqual(names, ["Day 2", "Day 10", "Real"])
        XCTAssertTrue(FolderAccess.hasSubfolders(root))
        XCTAssertFalse(FolderAccess.hasSubfolders(root.appendingPathComponent("Day 2")))
        XCTAssertTrue(FolderAccess.hasCatalog(root))
        XCTAssertFalse(FolderAccess.hasCatalog(root.appendingPathComponent("Real")))
        XCTAssertEqual(FolderAccess.subfolders(of: root.appendingPathComponent("Nope")), [], "unreadable lists nothing")
    }

    func testProblemOpeningAFolder() throws {
        XCTAssertNil(FolderAccess.problem(opening: root))
        XCTAssertEqual(FolderAccess.problem(opening: root.appendingPathComponent("Gone")), .missing)
        let offline = URL(fileURLWithPath: "/Volumes/Latent Test Share \(UUID().uuidString)/Shoot")
        XCTAssertEqual(FolderAccess.problem(opening: offline), .notConnected)
    }

    /// Foundation wraps the POSIX error the sandbox returns; either level
    /// is recognised, as are SQLite's own codes.
    func testErrorsAreSortedIntoTrouble() {
        let folder = URL(fileURLWithPath: "/Users/someone/Photos")
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 99999, userInfo: [NSUnderlyingErrorKey: posix])
        XCTAssertEqual(FolderAccess.trouble(for: wrapped, folder: folder), .notPermitted)
        XCTAssertEqual(FolderAccess.trouble(for: CocoaError(.fileWriteNoPermission), folder: folder), .notPermitted)
        XCTAssertEqual(FolderAccess.trouble(for: CocoaError(.fileWriteVolumeReadOnly), folder: folder), .readOnly)
        XCTAssertEqual(FolderAccess.trouble(for: DatabaseError(resultCode: .SQLITE_READONLY), folder: folder), .readOnly)
        XCTAssertEqual(FolderAccess.trouble(for: CocoaError(.fileNoSuchFile), folder: folder, exists: { _ in true }), .missing)
        let share = URL(fileURLWithPath: "/Volumes/Studio/2026")
        XCTAssertEqual(FolderAccess.trouble(for: CocoaError(.fileReadNoSuchFile), folder: share, exists: { _ in false }),
                       .notConnected)
        guard case .other = FolderAccess.trouble(for: CocoaError(.fileReadCorruptFile), folder: folder) else {
            return XCTFail("an unrelated error is passed through")
        }
    }

    func testDisconnectedVolumeIsOnlyAboutVolumes() {
        XCTAssertTrue(FolderAccess.isOnDisconnectedVolume("/Volumes/Card/DCIM", exists: { _ in false }))
        XCTAssertFalse(FolderAccess.isOnDisconnectedVolume("/Volumes/Card/DCIM", exists: { $0 == "/Volumes/Card" }))
        XCTAssertFalse(FolderAccess.isOnDisconnectedVolume("/Users/me/Pictures", exists: { _ in false }))
        XCTAssertFalse(FolderAccess.isOnDisconnectedVolume("/Volumes", exists: { _ in false }))
    }

    func testMessagesPointSomewhereUseful() {
        let folder = URL(fileURLWithPath: "/Users/me/Trip")
        XCTAssertTrue(FolderAccess.message(for: .notPermitted, folder: folder).contains("Open Folder…"))
        XCTAssertTrue(FolderAccess.message(for: .notConnected, folder: folder).contains("isn’t connected"))
        XCTAssertTrue(FolderAccess.message(for: .missing, folder: folder).contains("“Trip”"))
    }

    /// Every folder on the way down must be included, by its own mode or by
    /// the catalog's default where none is recorded.
    func testIsIncludedFollowsEveryLevel() {
        let modes: [String: SubfolderMode] = ["Day 2": .included, "Day 2/Raw": .independent, "Day 3": .ask]
        XCTAssertTrue(FolderAccess.isIncluded("Day 2", defaultMode: .ask, modes: modes))
        XCTAssertFalse(FolderAccess.isIncluded("Day 2/Raw", defaultMode: .included, modes: modes))
        XCTAssertFalse(FolderAccess.isIncluded("Day 2/Morning", defaultMode: .ask, modes: modes))
        XCTAssertTrue(FolderAccess.isIncluded("Day 2/Morning", defaultMode: .included, modes: modes))
        XCTAssertFalse(FolderAccess.isIncluded("Day 3", defaultMode: .included, modes: modes))
        XCTAssertFalse(FolderAccess.isIncluded("", defaultMode: .included, modes: modes))
    }

    /// An included subfolder belongs to the nearest catalog above it; an
    /// independent one, one with its own container, or one with no catalog
    /// above belongs to nobody.
    func testOwningCatalogReadsTheEnclosingCatalog() async throws {
        try makeFolders(["Day 2/Morning", "Day 3", "Own"])
        let catalog = try Catalog.open(at: root)
        try await catalog.setSubfolderMode(.included, forRelPath: "Day 2")
        try await catalog.setSubfolderMode(.independent, forRelPath: "Day 3")
        _ = try Catalog.open(at: root.appendingPathComponent("Own"))

        let owner = FolderAccess.owningCatalog(of: root.appendingPathComponent("Day 2"))
        XCTAssertEqual(owner?.relPath, "Day 2")
        XCTAssertTrue(owner.map { FolderAccess.samePath($0.root, root) } ?? false)
        XCTAssertNil(FolderAccess.owningCatalog(of: root.appendingPathComponent("Day 3")))
        XCTAssertNil(FolderAccess.owningCatalog(of: root.appendingPathComponent("Own")))
        XCTAssertNil(FolderAccess.owningCatalog(of: root.appendingPathComponent("Day 2/Morning")), "undecided below")
        XCTAssertNil(FolderAccess.owningCatalog(of: root), "a catalog's own folder")

        try await catalog.setDefaultSubfolderMode(.included)
        XCTAssertEqual(FolderAccess.owningCatalog(of: root.appendingPathComponent("Day 2/Morning"))?.relPath,
                       "Day 2/Morning")
    }

    func testChainAndBestRoot() {
        let a = URL(fileURLWithPath: "/P/Trips")
        let b = URL(fileURLWithPath: "/P/Trips/2026")
        let target = URL(fileURLWithPath: "/P/Trips/2026/Rome/")
        XCTAssertEqual(FolderAccess.chain(from: a, to: target)?.map(\.lastPathComponent), ["Trips", "2026", "Rome"])
        XCTAssertNil(FolderAccess.chain(from: URL(fileURLWithPath: "/P/Trip"), to: target))
        XCTAssertEqual(FolderAccess.bestRoot(for: target, among: [a, b]), 1)
        XCTAssertNil(FolderAccess.bestRoot(for: URL(fileURLWithPath: "/Q"), among: [a, b]))
        XCTAssertTrue(FolderAccess.samePath(URL(fileURLWithPath: "/P/Trips/"), a))
    }
}
