import XCTest
@testable import Catalog

/// Smart collection rules on their own, without a catalog.
final class SmartCollectionRulesTests: XCTestCase {
    private func record(_ name: String = "DSC_1.NEF", rating: Int = 0, flag: Int = 0, iso: Int? = nil,
                        camera: String? = nil, capture: Date? = nil, label: String? = nil) -> ImageRecord {
        ImageRecord(id: 1, relPath: name, size: 1, mtime: 0, xxhash: Data(count: 8),
                    captureTime: capture.map { Int64($0.timeIntervalSince1970) }, camera: camera, iso: iso,
                    rating: rating, label: label, flag: flag)
    }

    func testAllAndAny() {
        var rules = SmartCollectionRules(match: .all, criteria: [
            SmartCriterion(.rating, .atLeast, "3"),
            SmartCriterion(.flag, .is, "1"),
        ])
        XCTAssertTrue(rules.matches(record(rating: 4, flag: 1), isEdited: false, keywords: []))
        XCTAssertFalse(rules.matches(record(rating: 4, flag: 0), isEdited: false, keywords: []))
        rules.match = .any
        XCTAssertTrue(rules.matches(record(rating: 4, flag: 0), isEdited: false, keywords: []))
        XCTAssertFalse(rules.matches(record(rating: 1, flag: -1), isEdited: false, keywords: []))
        XCTAssertFalse(SmartCollectionRules().matches(record(), isEdited: false, keywords: []), "no rules, no photos")
    }

    func testFields() {
        let r = record("Trip/DSC_0042.NEF", rating: 2, iso: 3200, camera: "NIKON D750", label: "Red")
        func check(_ c: SmartCriterion, edited: Bool = false, keywords: Set<String> = [], _ expected: Bool,
                   line: UInt = #line) {
            XCTAssertEqual(c.matches(r, isEdited: edited, keywords: keywords), expected, "\(c)", line: line)
        }
        check(SmartCriterion(.iso, .atLeast, "1600"), true)
        check(SmartCriterion(.iso, .atMost, "1600"), false)
        check(SmartCriterion(.camera, .contains, "d750"), true)
        check(SmartCriterion(.camera, .is, "nikon d750"), true)
        check(SmartCriterion(.camera, .doesNotContain, "Canon"), true)
        check(SmartCriterion(.fileName, .startsWith, "DSC_"), true)
        check(SmartCriterion(.fileName, .endsWith, "42.nef"), true)
        check(SmartCriterion(.fileType, .is, ".nef"), true)
        check(SmartCriterion(.fileType, .isNot, "NEF"), false)
        check(SmartCriterion(.label, .is, "red"), true)
        check(SmartCriterion(.edited, .is, "true"), edited: true, true)
        check(SmartCriterion(.edited, .is, "false"), edited: true, false)
        check(SmartCriterion(.keyword, .is, "Places"), keywords: ["Places|France"], true)
        check(SmartCriterion(.keyword, .isNot, "Places"), keywords: ["Places|France"], false)
        check(SmartCriterion(.keyword, .contains, "fran"), keywords: ["Places|France"], true)
        check(SmartCriterion(.keyword, .doesNotContain, "fran"), keywords: ["sky"], true)
        check(SmartCriterion(.lens, .isNot, "50mm"), true)
        check(SmartCriterion(.lens, .is, "50mm"), false)
        check(SmartCriterion(.flag, .is, "1,0"), true)
        check(SmartCriterion(.rating, .is, "2"), true)
    }

    func testCaptureDates() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let calendar = Calendar.current
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        let r = record(capture: threeDaysAgo)
        XCTAssertTrue(SmartCriterion(.captureDate, .inLastDays, "7").matches(r, isEdited: false, keywords: [], now: now))
        XCTAssertFalse(SmartCriterion(.captureDate, .inLastDays, "2").matches(r, isEdited: false, keywords: [], now: now))
        let day = SmartCriterion.dayString(threeDaysAgo)
        XCTAssertTrue(SmartCriterion(.captureDate, .is, day).matches(r, isEdited: false, keywords: [], now: now))
        XCTAssertTrue(SmartCriterion(.captureDate, .before, SmartCriterion.dayString(now)).matches(r, isEdited: false, keywords: [], now: now))
        XCTAssertFalse(SmartCriterion(.captureDate, .after, day).matches(r, isEdited: false, keywords: [], now: now))
        XCTAssertFalse(SmartCriterion(.captureDate, .inLastDays, "7").matches(record(), isEdited: false, keywords: [], now: now),
                       "no capture time matches no date")
    }

    func testFromFilterAndJSONRoundTrip() throws {
        var filter = LibraryFilter()
        filter.minRating = 3
        filter.flags = [.picked, .none]
        filter.editedOnly = true
        filter.camera = "NIKON D750"
        filter.keyword = "Places|France"
        filter.text = "DSC"
        let rules = SmartCollectionRules(filter: filter)
        XCTAssertEqual(rules.criteria.count, 6)
        XCTAssertEqual(rules.criteria[1], SmartCriterion(.flag, .is, "1,0"))
        let matching = ImageRecord(id: 1, relPath: "DSC_1.NEF", size: 1, mtime: 0, xxhash: Data(count: 8),
                                   camera: "NIKON D750", rating: 4, flag: 0)
        // The rules say what the filter says.
        for (edited, keywords) in [(true, Set(["Places|France|Paris"])), (false, Set(["Places|France"])), (true, Set(["sky"]))] {
            XCTAssertEqual(rules.matches(matching, isEdited: edited, keywords: keywords),
                           filter.matches(matching, isEdited: edited, keywords: keywords))
        }
        XCTAssertEqual(SmartCollectionRules(json: rules.json), rules)
        XCTAssertNil(SmartCollectionRules(json: "{nonsense"))
    }

    func testStateTreeHelpers() {
        let state = CollectionsState(collections: [
            CatalogCollection(id: 1, name: "Travel", kind: .set),
            CatalogCollection(id: 2, name: "Lisbon", kind: .regular, parentID: 1),
            CatalogCollection(id: 3, name: "Good ones", kind: .smart, parentID: 1,
                              rules: SmartCollectionRules(criteria: [SmartCriterion(.rating, .atLeast, "4")])),
            CatalogCollection(id: 4, name: "Inner", kind: .set, parentID: 1),
            CatalogCollection(id: 5, name: "Alpha", kind: .regular),
        ], members: [2: [10, 11], 5: [12]])
        XCTAssertEqual(state.children(of: nil).map(\.id), [1, 5], "sets first")
        XCTAssertEqual(state.children(of: 1).map(\.id), [4, 3, 2])
        XCTAssertEqual(Set(state.subtree(1)), [1, 2, 3, 4])
        XCTAssertEqual(state.path(of: 2), "Travel › Lisbon")
        XCTAssertEqual(state.possibleParents(for: 1).map(\.id), [], "not into itself or what is inside it")
        XCTAssertEqual(state.possibleParents(for: 5).map(\.id), [1, 4])
        let scope = state.scope(for: 1)!
        XCTAssertEqual(scope.ids, [10, 11])
        XCTAssertEqual(scope.rules.count, 1)
        XCTAssertEqual(state.nextID, 6)
        XCTAssertEqual(state.pruned(toImages: [11]).members, [2: [11]])
        let ordered = Catalog.parentsFirst(state.collections.reversed())
        for (index, c) in ordered.enumerated() {
            if let parent = c.parentID { XCTAssertTrue(ordered.prefix(index).contains { $0.id == parent }) }
        }
    }
}

/// Collections in a real catalog: making them, filling them, showing them
/// in the grid, undo and redo, and what survives reopening the folder and
/// losing the database.
@MainActor
final class LibraryCollectionsTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-collections-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, name) in ["A.NEF", "B.NEF", "C.NEF"].enumerated() {
            try TestAssets.copyD750(to: folder.appendingPathComponent(name), variant: index + 1)
        }
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func open(_ manager: UndoManager = UndoManager()) async throws -> Library {
        let library = Library()
        library.undoManager = manager
        try await library.open(folder: folder)
        XCTAssertEqual(library.images.count, 3)
        return library
    }

    private func id(_ library: Library, _ name: String) -> Int64 {
        library.images.first { $0.fileName == name }!.id!
    }

    private func visibleNames(_ library: Library) -> [String] {
        library.visibleImages.map(\.fileName).sorted()
    }

    func testRegularCollectionShowsItsPhotosAndSurvivesReopening() async throws {
        let library = try await open()
        let (a, c) = (id(library, "A.NEF"), id(library, "C.NEF"))
        let collections = library.collections
        let lisbon = try XCTUnwrap(collections.create(name: "  Lisbon ", kind: .regular, adding: [a]))
        XCTAssertEqual(collections.state.collection(lisbon)?.name, "Lisbon")
        XCTAssertEqual(collections.add([a, c], to: lisbon), 1, "only C is new")
        collections.show(lisbon)
        XCTAssertEqual(visibleNames(library), ["A.NEF", "C.NEF"])
        // The filter bar narrows what the collection holds.
        library.filter.text = "C."
        XCTAssertEqual(visibleNames(library), ["C.NEF"])
        library.filter = LibraryFilter()
        collections.show(nil)
        XCTAssertEqual(library.visibleImages.count, 3)
        await collections.waitForSaves()

        let reopened = try await open()
        XCTAssertEqual(reopened.collections.state.collection(lisbon)?.name, "Lisbon")
        XCTAssertEqual(reopened.collections.state.members[lisbon], [a, c])
        reopened.collections.recount()
        XCTAssertEqual(reopened.collections.counts[lisbon], 2)
    }

    func testUndoAndRedoOfEveryKindOfChange() async throws {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let library = try await open(manager)
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))
        let collections = library.collections

        let set = try XCTUnwrap(collections.create(name: "Travel", kind: .set))
        let trip = try XCTUnwrap(collections.create(name: "Trip", kind: .regular, in: set))
        collections.add([a, b], to: trip)
        XCTAssertEqual(manager.undoActionName, "Add to Collection (2 Images)")
        collections.rename(trip, to: "Porto")
        collections.delete(set)
        XCTAssertTrue(collections.state.collections.isEmpty, "deleting a set deletes what is inside it")

        manager.undo()   // delete
        XCTAssertEqual(collections.state.collection(trip)?.parentID, set)
        XCTAssertEqual(collections.state.members[trip], [a, b])
        manager.undo()   // rename
        XCTAssertEqual(collections.state.collection(trip)?.name, "Trip")
        manager.undo()   // add
        XCTAssertNil(collections.state.members[trip])
        manager.redo()
        XCTAssertEqual(collections.state.members[trip], [a, b])
        manager.redo()
        XCTAssertEqual(collections.state.collection(trip)?.name, "Porto")
        await collections.waitForSaves()

        let stored = try await library.catalog!.loadCollections()
        XCTAssertEqual(stored, collections.state, "the catalog holds what is shown")
    }

    func testSmartCollectionFollowsRatings() async throws {
        let library = try await open()
        let b = id(library, "B.NEF")
        let collections = library.collections
        let rules = SmartCollectionRules(criteria: [SmartCriterion(.rating, .atLeast, "4")])
        let smart = try XCTUnwrap(collections.create(name: "Best", kind: .smart, rules: rules))
        collections.show(smart)
        XCTAssertEqual(library.visibleImages.count, 0)
        // As in Loupe: the photo shown is rated though the collection hides it.
        library.setSelection([b], primary: b)
        try await library.setRating(5, onlyPrimary: true)
        XCTAssertEqual(visibleNames(library), ["B.NEF"], "a rating change moves a photo into a smart collection at once")
        collections.recount()
        XCTAssertEqual(collections.counts[smart], 1)
        collections.setRules(SmartCollectionRules(criteria: [SmartCriterion(.rating, .atMost, "1")]), for: smart)
        XCTAssertEqual(visibleNames(library), ["A.NEF", "C.NEF"])
    }

    func testTargetCollectionToggles() async throws {
        let manager = UndoManager()
        manager.groupsByEvent = false
        let library = try await open(manager)
        let (a, b) = (id(library, "A.NEF"), id(library, "B.NEF"))
        let collections = library.collections
        XCTAssertEqual(collections.toggleInTarget([a, b]), "Added 2 photos to Quick Collection")
        let quick = try XCTUnwrap(collections.targetCollection)
        XCTAssertEqual(quick.name, LibraryCollections.quickCollectionName)
        XCTAssertEqual(collections.state.members[quick.id], [a, b])
        XCTAssertTrue(collections.targetContains([a]))
        XCTAssertEqual(collections.toggleInTarget([a]), "Removed 1 photo from Quick Collection")
        XCTAssertEqual(collections.state.members[quick.id], [b])
        manager.undo()
        XCTAssertEqual(collections.state.members[quick.id], [a, b])
        manager.undo()
        XCTAssertTrue(collections.state.collections.isEmpty, "the Quick Collection made by B goes with its undo")

        let other = try XCTUnwrap(collections.create(name: "Other", kind: .regular))
        collections.setTarget(other)
        collections.toggleInTarget([a])
        XCTAssertEqual(collections.state.members[other], [a])
        await collections.waitForSaves()
    }

    func testCollectionsComeBackFromTheBackupWhenTheDatabaseIsLost() async throws {
        let library = try await open()
        let a = id(library, "A.NEF")
        let collections = library.collections
        let set = try XCTUnwrap(collections.create(name: "Set", kind: .set))
        let keep = try XCTUnwrap(collections.create(name: "Keep", kind: .regular, in: set, adding: [a]))
        collections.setTarget(keep)
        _ = collections.create(name: "Smart", kind: .smart,
                               rules: SmartCollectionRules(criteria: [SmartCriterion(.fileName, .contains, "B")]))
        await collections.waitForSaves()

        let container = folder.appendingPathComponent(Catalog.containerName)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: container.appendingPathComponent("catalog.sqlite" + suffix))
        }
        let rebuilt = try await open()
        let state = rebuilt.collections.state
        XCTAssertEqual(Set(state.collections.map(\.name)), ["Set", "Keep", "Smart"])
        let restoredKeep = try XCTUnwrap(state.collections.first { $0.name == "Keep" })
        XCTAssertEqual(state.collection(restoredKeep.parentID)?.name, "Set")
        XCTAssertEqual(state.members[restoredKeep.id].map { ids in
            ids.compactMap { id in rebuilt.images.first { $0.id == id }?.fileName }
        }, ["A.NEF"], "members found again by path")
        XCTAssertEqual(state.targetID, restoredKeep.id)
        XCTAssertEqual(state.collections.first { $0.name == "Smart" }?.rules?.criteria.first?.value, "B")
    }

    func testDeletingEveryCollectionIsNotUndoneByTheBackup() async throws {
        let library = try await open()
        let only = try XCTUnwrap(library.collections.create(name: "Only", kind: .regular))
        library.collections.delete(only)
        await library.collections.waitForSaves()
        let reopened = try await open()
        XCTAssertTrue(reopened.collections.state.collections.isEmpty)
    }

    func testDroppedFileURLsMapToPhotos() async throws {
        let library = try await open()
        let urls = [folder.appendingPathComponent("B.NEF"), URL(fileURLWithPath: "/elsewhere/B.NEF")]
        XCTAssertEqual(library.collections.imageIDs(forFileURLs: urls), [id(library, "B.NEF")])
    }
}
