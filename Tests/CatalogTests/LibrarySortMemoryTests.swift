import XCTest
@testable import Catalog

/// Each sort key keeps its own direction, and the choice is stored.
@MainActor
final class LibrarySortMemoryTests: XCTestCase {
    func testKeysStartNaturallyAndRememberTheirDirection() {
        var memory = LibrarySortMemory()
        var sort = LibrarySort.default
        sort = memory.switching(from: sort, to: .fileName)
        XCTAssertEqual(sort, LibrarySort(key: .fileName, ascending: true), "A to Z first")
        sort.ascending = false
        sort = memory.switching(from: sort, to: .rating)
        XCTAssertEqual(sort, LibrarySort(key: .rating, ascending: false), "most stars first, not the last key's way")
        sort = memory.switching(from: sort, to: .fileName)
        XCTAssertEqual(sort, LibrarySort(key: .fileName, ascending: false), "Z to A, as it was left")
        XCTAssertEqual(memory.switching(from: sort, to: .fileName), sort, "the same key changes nothing")
        XCTAssertTrue(LibrarySortMemory.naturalAscending(.custom))
        XCTAssertFalse(LibrarySortMemory.naturalAscending(.modified))
    }

    func testStoredAndRestored() {
        var memory = LibrarySortMemory()
        var sort = memory.switching(from: .default, to: .fileName)
        sort.ascending = false
        sort = memory.switching(from: sort, to: .custom)
        let stored = memory.stored(showing: sort)
        // Through a property list, as UserDefaults keeps it.
        let data = try! PropertyListSerialization.data(fromPropertyList: stored, format: .binary, options: 0)
        let plist = try! PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let restored = LibrarySortMemory.restore(plist)
        XCTAssertEqual(restored.sort, LibrarySort(key: .custom, ascending: true))
        var back = restored.memory
        XCTAssertEqual(back.switching(from: restored.sort, to: .fileName), LibrarySort(key: .fileName, ascending: false))
        XCTAssertEqual(back.switching(from: .default, to: .captureTime), .default)

        XCTAssertEqual(LibrarySortMemory.restore(nil).sort, .default)
        XCTAssertEqual(LibrarySortMemory.restore(["key": "size", "ascending": ["size": true, "rating": 3]]).sort, .default,
                       "unknown keys and wrong types are ignored")
    }

    func testLibraryReportsChangesButNotRestores() {
        let library = Library()
        var reported: [LibrarySort] = []
        library.sortDidChange = { sort, _ in reported.append(sort) }
        library.restoreSort(["key": "rating", "ascending": ["rating": true]])
        XCTAssertEqual(library.sort, LibrarySort(key: .rating, ascending: true))
        XCTAssertEqual(reported, [], "putting the saved sort back isn't a change to save")
        library.chooseSortKey(.fileName)
        library.sort.ascending = false
        library.chooseSortKey(.rating)
        XCTAssertEqual(reported, [LibrarySort(key: .fileName, ascending: true),
                                  LibrarySort(key: .fileName, ascending: false),
                                  LibrarySort(key: .rating, ascending: true)])
        XCTAssertNotNil(library.sortDidChange, "still reporting after a restore")
    }
}
