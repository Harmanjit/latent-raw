import XCTest
@testable import Catalog

/// The smart collection fields, operators and per-line joins added after
/// the first release, on their own, without a catalog.
final class SmartCollectionExtrasTests: XCTestCase {
    private func record(_ path: String = "Trip/DSC_1.NEF", rating: Int = 0, iso: Int? = nil, shutter: Double? = nil,
                        width: Int? = nil, height: Int? = nil, capture: Date? = nil) -> ImageRecord {
        var r = ImageRecord(id: 1, relPath: path, size: 1, mtime: 0, xxhash: Data(count: 8),
                            captureTime: capture.map { Int64($0.timeIntervalSince1970) }, iso: iso, shutter: shutter,
                            width: width, height: height, rating: rating, flag: 0)
        r.title = "Sunset over Lisbon"
        r.creator = "Ana Silva"
        return r
    }

    func testOldRulesEncodeAndDecodeAsBefore() throws {
        // Written by the first release: no value2, no join.
        let old = #"{"criteria":[{"field":"rating","op":"atLeast","value":"3"},{"field":"camera","op":"contains","value":"D750"}],"match":"any"}"#
        let rules = try XCTUnwrap(SmartCollectionRules(json: old))
        XCTAssertEqual(rules.match, .any)
        XCTAssertNil(rules.criteria[1].join)
        XCTAssertNil(rules.criteria[0].value2)
        XCTAssertFalse(rules.hasJoins)
        XCTAssertEqual(rules.json, old, "an untouched rule encodes byte for byte as it was read")
        let between = SmartCollectionRules(criteria: [SmartCriterion(.iso, .between, "100", value2: "400", join: nil),
                                                      SmartCriterion(.rating, .is, "2", join: .except)])
        XCTAssertEqual(SmartCollectionRules(json: between.json), between)
    }

    func testJoinsReadLeftToRight() {
        let r = record(rating: 4, iso: 3200)
        func rules(_ match: SmartCollectionRules.Match, _ criteria: SmartCriterion...) -> SmartCollectionRules {
            SmartCollectionRules(match: match, criteria: criteria)
        }
        let rated = SmartCriterion(.rating, .atLeast, "3")
        let lowISO = SmartCriterion(.iso, .atMost, "400")
        // No joins: all / any exactly as before.
        XCTAssertFalse(rules(.all, rated, lowISO).matches(r, isEdited: false, keywords: []))
        XCTAssertTrue(rules(.any, rated, lowISO).matches(r, isEdited: false, keywords: []))
        // A line's own join wins over Match; lines without one follow Match.
        var or = lowISO; or.join = .or
        XCTAssertTrue(rules(.all, rated, or).matches(r, isEdited: false, keywords: []))
        var except = SmartCriterion(.iso, .atLeast, "1600"); except.join = .except
        XCTAssertFalse(rules(.all, rated, except).matches(r, isEdited: false, keywords: []))
        var and = lowISO; and.join = .and
        XCTAssertFalse(rules(.any, rated, and).matches(r, isEdited: false, keywords: []))
        // (false or true) except false → true; strictly left to right.
        var notFive = SmartCriterion(.rating, .is, "5"); notFive.join = .except
        XCTAssertTrue(rules(.all, lowISO, or.with(field: .rating, value: "4"), notFive).matches(r, isEdited: false, keywords: []))
        XCTAssertFalse(SmartCollectionRules(match: .all, criteria: []).matches(r, isEdited: false, keywords: []))
    }

    func testBetweenForNumbersAndDates() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let calendar = Calendar.current
        let threeDaysAgo = calendar.date(byAdding: .day, value: -3, to: now)!
        let r = record(rating: 3, iso: 800, capture: threeDaysAgo)
        XCTAssertTrue(SmartCriterion(.iso, .between, "400", value2: "800").matches(r, isEdited: false, keywords: []))
        XCTAssertTrue(SmartCriterion(.iso, .between, "1600", value2: "800").matches(r, isEdited: false, keywords: []),
                      "either way round")
        XCTAssertFalse(SmartCriterion(.iso, .between, "100", value2: "400").matches(r, isEdited: false, keywords: []))
        XCTAssertFalse(SmartCriterion(.iso, .between, "100", value2: nil).matches(r, isEdited: false, keywords: []))
        let day = SmartCriterion.dayString(threeDaysAgo)
        let today = SmartCriterion.dayString(now)
        XCTAssertTrue(SmartCriterion(.captureDate, .between, day, value2: today).matches(r, isEdited: false, keywords: [], now: now))
        XCTAssertTrue(SmartCriterion(.captureDate, .between, day, value2: day).matches(r, isEdited: false, keywords: [], now: now),
                      "both days count")
        let later = SmartCriterion.dayString(calendar.date(byAdding: .day, value: -2, to: now)!)
        XCTAssertFalse(SmartCriterion(.captureDate, .between, later, value2: today).matches(r, isEdited: false, keywords: [], now: now))
    }

    func testNewTextNumberAndShapeFields() {
        let r = record("Trip/Day 2/DSC_1.NEF", shutter: 1.0 / 250, width: 6000, height: 4000)
        func check(_ c: SmartCriterion, _ expected: Bool, line: UInt = #line) {
            XCTAssertEqual(c.matches(r, isEdited: false, keywords: []), expected, "\(c)", line: line)
        }
        check(SmartCriterion(.title, .contains, "lisbon"), true)
        check(SmartCriterion(.creator, .startsWith, "ana"), true)
        check(SmartCriterion(.caption, .isNot, "x"), true)
        check(SmartCriterion(.caption, .contains, "x"), false)
        check(SmartCriterion(.copyright, .doesNotContain, "©"), true)
        check(SmartCriterion(.folder, .startsWith, "Trip"), true)
        check(SmartCriterion(.folder, .is, "Trip/Day 2"), true)
        check(SmartCriterion(.folder, .is, "Trip"), false)
        check(SmartCriterion(.exposureTime, .atMost, "1/125"), true)
        check(SmartCriterion(.exposureTime, .is, "1/250"), true)
        check(SmartCriterion(.exposureTime, .atLeast, "0.5s"), false)
        check(SmartCriterion(.aspectRatio, .is, "landscape"), true)
        check(SmartCriterion(.aspectRatio, .isNot, "portrait"), true)
        check(SmartCriterion(.aspectRatio, .is, "3:2"), true)
        check(SmartCriterion(.aspectRatio, .between, "1.4", value2: "1.6"), true)
        check(SmartCriterion(.aspectRatio, .atLeast, "16/9"), false)
        var turned = r
        turned.userRotation = 1
        XCTAssertTrue(SmartCriterion(.aspectRatio, .is, "portrait").matches(turned, isEdited: false, keywords: []))
        var square = r
        square.height = 6000
        XCTAssertTrue(SmartCriterion(.aspectRatio, .is, "square").matches(square, isEdited: false, keywords: []))
    }

    func testKeywordFileTypeKindAndContextFields() {
        let r = record()
        XCTAssertTrue(SmartCriterion(.keyword, .hasNoKeywords, "").matches(r, isEdited: false, keywords: []))
        XCTAssertFalse(SmartCriterion(.keyword, .hasNoKeywords, "").matches(r, isEdited: false, keywords: ["sky"]))
        XCTAssertTrue(SmartCriterion(.keyword, .hasAnyKeyword, "").matches(r, isEdited: false, keywords: ["sky"]))
        XCTAssertTrue(SmartCriterion(.fileType, .isRaw, "").matches(r, isEdited: false, keywords: []))
        XCTAssertTrue(SmartCriterion(.fileType, .isNotRaw, "").matches(record("a.jpg"), isEdited: false, keywords: []))
        XCTAssertTrue(SmartCriterion(.fileType, .isRaw, "").matches(record("a.dng"), isEdited: false, keywords: []))

        let copy = record("Trip/DSC_1.NEF#vc002-1a2b3c4d")
        XCTAssertTrue(copy.isVirtualCopy)
        XCTAssertTrue(SmartCriterion(.virtualCopy, .is, "true").matches(copy, isEdited: false, keywords: []))
        XCTAssertTrue(SmartCriterion(.kind, .is, "master").matches(r, isEdited: false, keywords: []))
        XCTAssertTrue(SmartCriterion(.kind, .is, "virtualCopy").matches(copy, isEdited: false, keywords: []))
        XCTAssertEqual(SmartCriterion.folder(of: copy), "Trip")
        let extras = SmartScopeExtras(stackedIDs: [1], mastersWithCopies: SmartScopeExtras.masters(withCopiesIn: [r, copy]),
                                      editGroups: [1: ["tone", "crop"]], editTimes: [1: 1_780_000_000_000])
        let context = extras.context(for: r, isEdited: true, keywords: [], now: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertTrue(context.hasVirtualCopies)
        XCTAssertTrue(SmartCriterion(.kind, .is, "hasVirtualCopies").matches(r, context: context))
        XCTAssertFalse(SmartCriterion(.kind, .is, "hasVirtualCopies").matches(copy, context: extras.context(
            for: copy, isEdited: false, keywords: [], now: Date())))
        XCTAssertTrue(SmartCriterion(.inStack, .is, "true").matches(r, context: context))
        XCTAssertTrue(SmartCriterion(.moduleUsed, .is, "crop").matches(r, context: context))
        XCTAssertTrue(SmartCriterion(.moduleUsed, .isNot, "colour").matches(r, context: context))
        XCTAssertTrue(SmartCriterion(.modifiedDate, .inLastDays, "1").matches(r, context: context))
        XCTAssertFalse(SmartCriterion(.modifiedDate, .inLastDays, "1").matches(r, isEdited: false, keywords: []),
                       "no edit, no edit date")
        let rules = SmartCollectionRules(criteria: [SmartCriterion(.moduleUsed, .is, "crop"), SmartCriterion(.inStack, .is, "true")])
        XCTAssertTrue(rules.readsEditDetails && rules.readsStacks && !rules.readsVirtualCopyMasters)
        let scope = CollectionScope(ids: [], rules: [rules], extras: extras)
        XCTAssertTrue(scope.includes(r, isEdited: true, keywords: []))
    }

    func testExistingValuesAndRecents() {
        var a = record("Trip/A.NEF"); a.camera = "NIKON D750"
        var b = record("B.jpg"); b.camera = "Canon R5"; b.title = nil
        XCTAssertEqual(SmartCriterion.existingValues(for: .camera, in: [a, b, a]), ["Canon R5", "NIKON D750"])
        XCTAssertEqual(SmartCriterion.existingValues(for: .fileType, in: [a, b]), ["JPG", "NEF"])
        XCTAssertEqual(SmartCriterion.existingValues(for: .folder, in: [a, b]), ["Trip"], "the top level has no name")
        XCTAssertEqual(SmartCriterion.existingValues(for: .keyword, in: [], keywords: [1: ["sky", "Places|Paris"]]),
                       ["Places|Paris", "sky"])
        XCTAssertEqual(SmartCriterion.existingValues(for: .rating, in: [a]), [])

        var list: [Int64] = []
        for id in [1, 2, 3, 2] as [Int64] { list = RecentCollections.recording(id, in: list) }
        XCTAssertEqual(list, [2, 3, 1])
        for id in 10...20 as ClosedRange<Int64> { list = RecentCollections.recording(id, in: list) }
        XCTAssertEqual(list.count, RecentCollections.limit)
        let state = CollectionsState(collections: [CatalogCollection(id: 20, name: "A", kind: .regular),
                                                   CatalogCollection(id: 18, name: "B", kind: .smart)])
        XCTAssertEqual(RecentCollections.existing(list, in: state), [20, 18])
    }
}

private extension SmartCriterion {
    func with(field: Field, value: String) -> SmartCriterion {
        var copy = self
        copy.field = field
        copy.op = .is
        copy.value = value
        return copy
    }
}

/// The app-wide keyword dictionary and keyword co-occurrence.
final class KeywordDictionaryTests: XCTestCase {
    func testInsertRenameRemoveAndText() throws {
        var d = KeywordDictionary()
        XCTAssertTrue(d.insert(["Places > France > Paris", "sky", " sky "]))
        XCTAssertFalse(d.insert(["sky"]))
        XCTAssertEqual(d.paths, ["Places|France|Paris", "sky"])
        XCTAssertEqual(d.allPaths, ["Places", "Places|France", "Places|France|Paris", "sky"])
        XCTAssertTrue(d.rename("Places|France", to: "Europe|France"))
        XCTAssertEqual(d.paths, ["Europe|France|Paris", "sky"])
        XCTAssertTrue(d.rename("Europe", to: "World|Europe"), "a level that only exists above another moves too")
        XCTAssertEqual(d.paths, ["World|Europe|France|Paris", "sky"])
        d.insert(["World|Europe"])
        XCTAssertEqual(d.text, "sky\nWorld|Europe|France|Paris\n", "only the innermost paths are written")
        XCTAssertTrue(d.remove("World|Europe"))
        XCTAssertEqual(d.paths, ["sky"])

        let parsed = KeywordDictionary.paths(fromText: "# mine\nPlaces|France\n\n\tanimals > dog\r\nPlaces|France\n")
        XCTAssertEqual(parsed, ["Places|France", "animals|dog"])

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("latent-dict-\(UUID().uuidString)/d.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(KeywordDictionary.load(from: url), KeywordDictionary(), "none yet is empty")
        let saved = KeywordDictionary(paths: parsed)
        try saved.save(to: url)
        XCTAssertEqual(KeywordDictionary.load(from: url), saved)
    }

    func testTreeWithDictionaryKeywordsAndCooccurrence() {
        let index: [Int64: Set<String>] = [1: ["sky", "Places|Paris"], 2: ["sky", "sea"], 3: ["sky", "sea", "boat"], 4: ["dog"]]
        let tree = KeywordTree.build(from: index, including: ["Places|Lyon", "zebra"])
        XCTAssertEqual(tree.map(\.name), ["boat", "dog", "Places", "sea", "sky", "zebra"])
        let places = tree.first { $0.path == "Places" }!
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.children.map(\.name), ["Lyon", "Paris"])
        XCTAssertEqual(places.children.first?.count, 0)
        XCTAssertEqual(KeywordTree.build(from: index, including: []), KeywordTree.build(from: index))

        XCTAssertEqual(KeywordPath.cooccurring(with: ["sky"], in: index), ["sea", "boat", "Places|Paris"])
        XCTAssertEqual(KeywordPath.cooccurring(with: ["sky"], in: index, limit: 1), ["sea"])
        XCTAssertEqual(KeywordPath.cooccurring(with: [], in: index), [])
    }
}

/// The new fields in a real catalog: Kind and In a stack follow virtual
/// copies and stacks, Edit changes and Edit date follow saved edits, and
/// photos dropped on a keyword get it as one undo step.
@MainActor
final class SmartCollectionLibraryTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-smart-extras-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, name) in ["A.NEF", "B.NEF", "C.NEF"].enumerated() {
            try TestAssets.copyD750(to: folder.appendingPathComponent(name), variant: index + 1)
        }
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func open(_ manager: UndoManager = UndoManager()) async throws -> Library {
        let library = Library()
        library.undoManager = manager
        try await library.open(folder: folder)
        XCTAssertEqual(library.images.count, 3)
        return library
    }

    private func record(_ library: Library, _ name: String) -> ImageRecord {
        library.images.first { $0.fileName == name }!
    }

    func testKindStackAndEditDetails() async throws {
        let library = try await open()
        let collections = library.collections
        collections.editGroupsReader = { json in json.contains("crop") ? ["crop"] : [] }
        let a = record(library, "A.NEF"), b = record(library, "B.NEF")
        try await library.createVirtualCopies(of: [a])
        XCTAssertEqual(library.images.count, 4)

        let masters = try XCTUnwrap(collections.create(name: "Masters with copies", kind: .smart, rules:
            SmartCollectionRules(criteria: [SmartCriterion(.kind, .is, "hasVirtualCopies")])))
        let copies = try XCTUnwrap(collections.create(name: "Copies", kind: .smart, rules:
            SmartCollectionRules(criteria: [SmartCriterion(.kind, .is, "virtualCopy")])))
        collections.show(masters)
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["A.NEF"])
        collections.recount()
        XCTAssertEqual(collections.counts[copies], 1)

        let stacked = try XCTUnwrap(collections.create(name: "Stacked", kind: .smart, rules:
            SmartCollectionRules(criteria: [SmartCriterion(.inStack, .is, "true")])))
        collections.show(stacked)
        XCTAssertEqual(library.visibleImages.count, 0)
        try await library.groupIntoStack([record(library, "B.NEF"), record(library, "C.NEF")])
        // A new stack is collapsed, so the grid shows its top; both count.
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["B.NEF"])
        collections.recount()
        XCTAssertEqual(collections.counts[stacked], 2)

        let cropped = try XCTUnwrap(collections.create(name: "Cropped", kind: .smart, rules:
            SmartCollectionRules(criteria: [SmartCriterion(.moduleUsed, .is, "crop"),
                                            SmartCriterion(.modifiedDate, .inLastDays, "1", join: .and)])))
        collections.show(cropped)
        try await library.saveEditStack(#"{"crop":{}}"#, schemaVersion: 1, processVersion: "1.0", forImageID: b.id!)
        // The edits are read again in the background after the change settles.
        for _ in 0..<100 where library.visibleImages.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["B.NEF"])
    }

    func testDroppedPhotosGetAKeywordAsOneUndoStep() async throws {
        let manager = UndoManager()
        let library = try await open(manager)
        let ids = Set([record(library, "A.NEF"), record(library, "C.NEF")].compactMap(\.id))
        try await library.addKeywords(["Places > Lisbon"], toImageIDs: ids)
        XCTAssertEqual(manager.undoActionName, "Add Keyword (2 Images)")
        XCTAssertEqual(library.keywordsByImage.filter { $0.value.contains("Places|Lisbon") }.count, 2)
        XCTAssertEqual(library.keywordsOftenUsed(with: ["Places|Lisbon"]), [])
        manager.undo()
        await library.waitForPendingWork()
        XCTAssertTrue(library.keywordsByImage.values.allSatisfy { !$0.contains("Places|Lisbon") })
    }
}
