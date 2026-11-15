import XCTest
@testable import Catalog

/// The "File integrity is damaged / ok / unchecked" smart collection rule,
/// the filter bar's File integrity choice, and Save Filter as Smart
/// Collection carrying it.
@MainActor
final class FileIntegrityRuleTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-integrity-rule-\(UUID().uuidString)",
                                                              isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func record(_ id: Int64, size: Int64 = 100, mtime: Int64 = 5) -> ImageRecord {
        ImageRecord(id: id, relPath: "IMG_\(id).NEF", preservedName: nil, size: size, mtime: mtime,
                    xxhash: Data(count: 8), captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil,
                    shutter: nil, aperture: nil, focal: nil, width: 6000, height: 4000, orientation: nil, rating: 0,
                    label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil)
    }

    // MARK: Pure parts

    func testStateOfAnImage() {
        XCTAssertEqual(FileIntegrity.State.of(1, damaged: [1], verified: [1]), .damaged, "damaged wins")
        XCTAssertEqual(FileIntegrity.State.of(2, damaged: [1], verified: [2]), .ok)
        XCTAssertEqual(FileIntegrity.State.of(3, damaged: [1], verified: [2]), .unchecked)
        XCTAssertEqual(FileIntegrity.State.of(nil, damaged: [1], verified: [2]), .unchecked)
    }

    func testRuleMatchesEachState() {
        let extras = SmartScopeExtras(damagedIDs: [1], verifiedIDs: [2])
        let now = Date()
        func matches(_ op: SmartCriterion.Operator, _ value: String, _ id: Int64) -> Bool {
            let r = record(id)
            let rules = SmartCollectionRules(criteria: [SmartCriterion(.fileIntegrity, op, value)])
            return rules.matches(r, context: extras.context(for: r, isEdited: false, keywords: [], now: now))
        }
        XCTAssertTrue(matches(.is, "damaged", 1))
        XCTAssertFalse(matches(.is, "damaged", 2))
        XCTAssertFalse(matches(.is, "damaged", 3))
        XCTAssertTrue(matches(.is, "ok", 2))
        XCTAssertFalse(matches(.is, "ok", 1))
        XCTAssertTrue(matches(.is, "unchecked", 3))
        XCTAssertFalse(matches(.is, "unchecked", 2))
        XCTAssertTrue(matches(.isNot, "damaged", 2))
        XCTAssertTrue(matches(.isNot, "damaged", 3))
        XCTAssertFalse(matches(.isNot, "damaged", 1))
        XCTAssertTrue(matches(.is, " OK ", 2), "the value is read leniently")
        XCTAssertFalse(matches(.is, "nonsense", 1), "an unknown value matches nothing")
        XCTAssertFalse(matches(.isNot, "nonsense", 1))
    }

    func testRuleFieldDescribesItself() throws {
        let field = SmartCriterion.Field.fileIntegrity
        XCTAssertEqual(field.operators, [.is, .isNot])
        XCTAssertEqual(field.valueKind, .integrity)
        XCTAssertEqual(SmartCriterion(field: field).value, "damaged")
        let rules = SmartCollectionRules(criteria: [SmartCriterion(field: field)])
        XCTAssertTrue(rules.readsIntegrity)
        XCTAssertFalse(SmartCollectionRules(criteria: [SmartCriterion(field: .rating)]).readsIntegrity)
        XCTAssertEqual(SmartCollectionRules(json: rules.json), rules, "survives the catalog's JSON")
        // A changed file voids its check, so the grid filters again.
        XCTAssertTrue(rules.dependsOnChange(from: record(1), to: record(1, mtime: 9)))
        XCTAssertTrue(rules.dependsOnChange(from: record(1), to: record(1, size: 7)))
        var rated = record(1)
        rated.rating = 3
        XCTAssertFalse(rules.dependsOnChange(from: record(1), to: rated))
        // Rules without it read and match exactly as before.
        let old = try XCTUnwrap(SmartCollectionRules(json: #"{"match":"all","criteria":[{"field":"rating","op":"atLeast","value":"0"}]}"#))
        XCTAssertFalse(old.readsIntegrity)
    }

    func testFilterChoiceFiltersAndIsSaved() throws {
        var filter = LibraryFilter()
        XCTAssertFalse(filter.isActive)
        filter.integrity = .damaged
        XCTAssertTrue(filter.isActive)
        let context = LibraryFilterContext(filter: filter, images: [], pairedCompanions: [:],
                                           damagedIDs: [1], verifiedIDs: [2])
        XCTAssertTrue(filter.matches(record(1), isEdited: false, keywords: [], context: context))
        XCTAssertFalse(filter.matches(record(2), isEdited: false, keywords: [], context: context))
        filter.integrity = .unchecked
        XCTAssertTrue(filter.matches(record(3), isEdited: false, keywords: [], context: context))
        XCTAssertFalse(filter.matches(record(1), isEdited: false, keywords: [], context: context))

        // Filter presets keep it; one saved before it existed reads as any.
        let data = try JSONEncoder().encode(filter)
        XCTAssertEqual(try JSONDecoder().decode(LibraryFilter.self, from: data).integrity, .unchecked)
        XCTAssertNil(try JSONDecoder().decode(LibraryFilter.self, from: Data(#"{"minRating":2}"#.utf8)).integrity)
        let neutral = String(decoding: try JSONEncoder().encode(LibraryFilter()), as: UTF8.self)
        XCTAssertFalse(neutral.contains("integrity"))
    }

    func testSaveFilterAsSmartCollectionCarriesIntegrity() {
        var filter = LibraryFilter()
        filter.minRating = 2
        XCTAssertFalse(SmartCollectionRules(filter: filter).criteria.contains { $0.field == .fileIntegrity })
        filter.integrity = .damaged
        let rules = SmartCollectionRules(filter: filter)
        XCTAssertEqual(rules.criteria.last, SmartCriterion(.fileIntegrity, .is, "damaged"))
        // The collection shows what the filter showed.
        let extras = SmartScopeExtras(damagedIDs: [1], verifiedIDs: [2])
        var damagedRated = record(1)
        damagedRated.rating = 3
        var okRated = record(2)
        okRated.rating = 3
        let now = Date()
        XCTAssertTrue(rules.matches(damagedRated, context: extras.context(for: damagedRated, isEdited: false,
                                                                          keywords: [], now: now)))
        XCTAssertFalse(rules.matches(okRated, context: extras.context(for: okRated, isEdited: false,
                                                                      keywords: [], now: now)))
    }

    // MARK: A real folder

    func testVerifiedAndDamagedReachRulesAndFilter() async throws {
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
        let library = Library()
        library.undoManager = UndoManager()
        try await library.open(folder: folder)
        let catalog = try XCTUnwrap(library.catalog)
        let a = try XCTUnwrap(library.images.first { $0.fileName == "A.NEF" })
        let b = try XCTUnwrap(library.images.first { $0.fileName == "B.NEF" })
        XCTAssertEqual(library.integrityState(of: a), .unchecked)

        // A verified intact, B found damaged.
        let checks = [
            FileIntegrity.Check(imageID: a.id!, relPath: a.relPath, fileName: a.fileName, status: .verified,
                                size: a.size, mtime: a.mtime),
            FileIntegrity.Check(imageID: b.id!, relPath: b.relPath, fileName: b.fileName, status: .damaged,
                                size: b.size, mtime: b.mtime),
        ]
        try await library.recordVerification(checks, in: catalog)
        let verified = try await catalog.verifiedImageIDs()
        XCTAssertEqual(verified, [a.id!])
        XCTAssertEqual(library.verifiedImageIDs, [a.id!])
        XCTAssertEqual(library.damagedImageIDs, [b.id!])
        XCTAssertEqual(library.integrityState(of: a), .ok)
        XCTAssertEqual(library.integrityState(of: b), .damaged)

        // The filter bar's choice.
        var filter = LibraryFilter()
        filter.integrity = .damaged
        library.filter = filter
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["B.NEF"])
        filter.integrity = .ok
        library.filter = filter
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["A.NEF"])
        library.filter = LibraryFilter()

        // A smart collection made from it.
        filter.integrity = .damaged
        let id = try XCTUnwrap(library.collections.create(name: "Damaged", kind: .smart,
                                                          rules: SmartCollectionRules(filter: filter)))
        library.collections.recount()
        XCTAssertEqual(library.collections.counts[id], 1)
        library.collections.show(id)
        XCTAssertEqual(library.visibleImages.map(\.fileName), ["B.NEF"])
        await library.collections.waitForSaves()

        // Opening the folder again reads both back.
        try await library.refresh()
        XCTAssertEqual(library.verifiedImageIDs, [a.id!])
        XCTAssertEqual(library.damagedImageIDs, [b.id!])
    }
}
