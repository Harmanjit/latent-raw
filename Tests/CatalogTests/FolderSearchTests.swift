import XCTest
@testable import Catalog

final class FolderSearchTests: XCTestCase {
    func testFindsFoldersByNameNearestFirst() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("Photos-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        for path in ["2026/Lisbon/Day 1", "2026/Porto", "2025/lisbon trip", "Archive/Deep/Deeper/Lisboa",
                     "_latent/Lisbon", ".hidden/Lisbon"] {
            try fm.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let found = FolderSearch.find("LISBON", under: [root])
        XCTAssertEqual(found.map(\.url.lastPathComponent), ["lisbon trip", "Lisbon"],
                       "catalog containers and hidden folders are skipped; nearer levels first")
        XCTAssertEqual(found.last?.trail, "\(root.lastPathComponent) › 2026")
        XCTAssertEqual(FolderSearch.find("lisbo", under: [root]).map(\.url.lastPathComponent),
                       ["lisbon trip", "Lisbon", "Lisboa"])
        XCTAssertEqual(FolderSearch.find("lisbo", under: [root], maxDepth: 2).count, 2)
        XCTAssertEqual(FolderSearch.find("lis", under: [root], limit: 1).count, 1)
        XCTAssertEqual(FolderSearch.find("  ", under: [root]), [])
        XCTAssertEqual(FolderSearch.find("Photos", under: [root]).map(\.url), [root], "a favourite matches itself")
    }
}
