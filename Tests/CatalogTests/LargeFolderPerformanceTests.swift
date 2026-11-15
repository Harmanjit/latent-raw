import XCTest
import GRDB
@testable import Catalog

/// The newest Library features on a 10,000-photo folder: the filter bar's
/// range histograms and search, smart collections with the newer fields and
/// per-line joins, rating under an active collection, and the keyword
/// suggestions and dictionary. Each test checks the answer and prints its
/// time as a `PERF` line in the test log.
///
/// The folder is made up (`LargeFolderFixture`), and one test also writes
/// it to a real catalog in a temporary directory and reads it back, as
/// opening the folder does. Nothing large is committed.
///
/// The bounds are loose, to catch an accidental O(n²) rather than a few
/// per cent. On CI's shared runners the timing tests are skipped unless
/// `LATENT_PERF=1`; locally they always run:
///
///     swift test --filter LargeFolderPerformanceTests
@MainActor
final class LargeFolderPerformanceTests: XCTestCase {
    nonisolated static let count = 10_000

    /// Skips the timing tests on CI unless asked for.
    private func requireTiming() throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["CI"] != nil, environment["LATENT_PERF"] != "1" {
            throw XCTSkip("timing tests run on CI only with LATENT_PERF=1")
        }
    }

    /// Seconds for `body`, best of `runs`.
    private func time(runs: Int = 3, _ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        return best
    }

    private func report(_ what: String, _ seconds: Double) {
        print(String(format: "PERF %@: %.2f ms", what, seconds * 1000))
    }

    private func library(_ fixture: LargeFolderFixture = LargeFolderFixture()) -> Library {
        let library = Library()
        library.replaceImagesForTesting(fixture.records)
        library.keywordIndex = fixture.keywords
        return library
    }

    // MARK: - A real catalog

    /// Writes the made-up folder to a catalog in a temporary directory and
    /// reads it back the way opening a folder does (every row, then every
    /// keyword in one query), so the rest of these tests start from what a
    /// real 10,000-photo catalog holds.
    func testSyntheticCatalogRoundTrips() async throws {
        try requireTiming()
        let fixture = LargeFolderFixture()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-perf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let catalog = try Catalog.open(at: folder)
        let records = fixture.records, keywords = fixture.keywords
        try await catalog.dbQueue.write { db in
            for var record in records {
                let id = record.id
                record.id = nil
                try record.insert(db)
                if let id, let names = keywords[id] {
                    try Catalog.replaceKeywords(names.sorted(), forImageID: record.id!, in: db)
                }
            }
        }
        var loaded: [ImageRecord] = []
        var index: [Int64: Set<String>] = [:]
        let start = DispatchTime.now().uptimeNanoseconds
        loaded = try await catalog.allImages()
        index = try await catalog.allImageKeywords()
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        report("catalog read, \(Self.count) rows + keywords", seconds)
        XCTAssertEqual(loaded.count, Self.count)
        XCTAssertEqual(index.values.reduce(0) { $0 + $1.count }, keywords.values.reduce(0) { $0 + $1.count })
        XCTAssertLessThan(seconds, 5)
    }

    // MARK: - Filter bar

    /// The Ranges popover's four histograms, worked out as it opens.
    func testRangeHistograms() throws {
        try requireTiming()
        let library = library()
        var histograms: [RangeHistogram] = []
        let seconds = time {
            let records = library.imagesInScope
            histograms = [
                RangeHistogram(values: records.compactMap { $0.iso.map(Double.init) }),
                RangeHistogram(values: records.compactMap(\.focal)),
                RangeHistogram(values: records.compactMap(\.aperture)),
                RangeHistogram(values: records.compactMap(\.shutter)),
            ]
        }
        report("range histograms, 10k", seconds)
        XCTAssertEqual(histograms[0].counts.reduce(0, +), library.images.filter { ($0.iso ?? 0) > 0 }.count)
        XCTAssertLessThan(seconds, 0.25)
    }

    /// Typing in the search field: every keystroke filters and sorts the
    /// whole folder again, on the main thread.
    func testTypingInTheSearchField() throws {
        try requireTiming()
        for scope in [TextSearchScope.names, .everything] {
            let library = library()
            library.filter.textScope = scope
            let typed = scope == .names ? "dsc_01" : "harbour paris"
            var keystrokes = 0
            let seconds = time(runs: 2) {
                library.filter.text = ""
                for end in typed.indices {
                    library.filter.text = String(typed[...end])
                    keystrokes += 1
                }
            }
            keystrokes /= 2
            report("search keystroke (\(scope.rawValue)), 10k, average", seconds / Double(keystrokes))
            XCTAssertFalse(library.visibleImages.isEmpty)
            XCTAssertLessThan(seconds / Double(keystrokes), 0.1)
        }
    }

    /// The everything search finds what a fresh haystack per record finds,
    /// before and after keywords change.
    func testEverythingSearchMatchesFreshHaystacks() {
        let fixture = LargeFolderFixture(count: 2_000)
        let library = library(fixture)
        library.filter.textScope = .everything
        library.filter.text = "harbour \"day 10\" -lisbon"
        func expected() -> [Int64?] {
            let query = SearchQuery(library.filter.text)
            return library.images.filter { record in
                query.matches(LibraryFilter.searchHaystack(record, keywords: record.id.flatMap { library.keywordIndex[$0] } ?? []))
            }.sorted(by: library.sort).map(\.id)
        }
        XCTAssertEqual(library.visibleImages.map(\.id), expected())
        XCTAssertFalse(library.visibleImages.isEmpty)
        // A keyword added to a photo that didn't match makes it match.
        let visible = Set(library.visibleImages.compactMap(\.id))
        let other = library.images.first { library.keywordIndex[$0.id!] == nil && !visible.contains($0.id!) }!
        var index = library.keywordIndex
        index[other.id!, default: []].insert("Harbour Day 10")
        library.keywordIndex = index
        XCTAssertTrue(library.visibleImages.contains { $0.id == other.id })
        XCTAssertEqual(library.visibleImages.map(\.id), expected())
        // A renamed record is searched by its new title.
        var renamed = library.images[5]
        renamed.title = "harbour day 10 extra"
        library.patchRecordsForTesting([renamed.id!: renamed])
        XCTAssertEqual(library.visibleImages.map(\.id), expected())
    }

    // MARK: - Smart collections

    /// Rules with the newer fields and per-line joins, as `recount` and the
    /// grid evaluate them: every photo against every rule.
    static let smartRules: [SmartCollectionRules] = [
        SmartCollectionRules(match: .all, criteria: [
            SmartCriterion(.captureDate, .between, "2023-11-01", value2: "2023-11-30"),
            SmartCriterion(.title, .contains, "harbour", join: .or),
            SmartCriterion(.folder, .startsWith, "2023/Day 0", join: .and),
            SmartCriterion(.exposureTime, .between, "1/1000", value2: "1/60", join: .except),
        ]),
        SmartCollectionRules(match: .any, criteria: [
            SmartCriterion(.captureDate, .inLastDays, "30"),
            SmartCriterion(.kind, .is, SmartCriterion.Kind.hasVirtualCopies.rawValue),
            SmartCriterion(.keyword, .contains, "lisbon"),
        ]),
        SmartCollectionRules(match: .all, criteria: [
            SmartCriterion(.captureDate, .after, "2023-10-12"),
            SmartCriterion(.aspectRatio, .is, "landscape"),
            SmartCriterion(.creator, .is, "Ana", join: .and),
            SmartCriterion(.flag, .is, "1,0"),
        ]),
    ]

    func testSmartCollectionEvaluation() throws {
        try requireTiming()
        let library = library()
        let now = Date(timeIntervalSince1970: 1_700_900_000)
        let edited = library.editedImageIDs, keywords = library.keywordIndex
        var matched = 0
        let scope = CollectionScope(ids: [], rules: Self.smartRules,
                                    extras: SmartScopeExtras(mastersWithCopies: SmartScopeExtras.masters(withCopiesIn: library.images)))
        let seconds = time {
            matched = library.images.lazy.filter { record in
                scope.includes(record, isEdited: record.id.map(edited.contains) ?? false,
                               keywords: record.id.flatMap { keywords[$0] } ?? [], now: now)
            }.count
        }
        report("smart collection (3 rule sets, joins, dates), 10k", seconds)
        XCTAssertGreaterThan(matched, 0)
        XCTAssertLessThan(matched, Self.count)
        XCTAssertLessThan(seconds, 0.5)
    }

    /// The sidebar's counts with eight collections, regular and smart.
    func testCollectionCountsAndActiveScope() throws {
        try requireTiming()
        let library = library()
        let ids = library.images.compactMap(\.id)
        var collections: [CatalogCollection] = []
        var members: [Int64: Set<Int64>] = [:]
        for index in 0..<4 {
            let id = Int64(index + 1)
            collections.append(CatalogCollection(id: id, name: "Regular \(index)", kind: .regular))
            members[id] = Set(ids.enumerated().filter { $0.offset % (index + 2) == 0 }.map(\.element))
        }
        for (index, rules) in Self.smartRules.enumerated() {
            collections.append(CatalogCollection(id: Int64(10 + index), name: "Smart \(index)", kind: .smart, rules: rules))
        }
        collections.append(CatalogCollection(id: 20, name: "Set", kind: .set))
        collections[0].parentID = 20
        collections[5].parentID = 20   // Smart 1, whose rules read virtual copies
        library.collections.catalogDidLoad(CollectionsState(collections: collections, members: members), isNewCatalog: true)
        let seconds = time { library.collections.recount() }
        report("collection counts, 9 collections, 10k", seconds)
        XCTAssertEqual(library.collections.counts[1], members[1]!.count)
        XCTAssertLessThan(seconds, 1)

        // Rating 2,000 photos while a collection whose rules read virtual
        // copies is shown: each changed record asked for the active scope,
        // which gathered the folder's virtual copies again.
        library.collections.show(20)
        XCTAssertFalse(library.visibleImages.isEmpty)
        var fresh: [Int64: ImageRecord] = [:]
        for record in library.images.prefix(2_000) {
            var changed = record
            changed.title = (record.title ?? "") + " (rated)"
            fresh[record.id!] = changed
        }
        let patch = time(runs: 1) { library.patchRecordsForTesting(fresh) }
        report("2,000 records patched under an active collection set, 10k", patch)
        XCTAssertLessThan(patch, 1)
    }

    /// Smart rule results don't change with the caching of parsed values.
    func testSmartRulesAgreeWithPlainEvaluation() {
        let now = Date(timeIntervalSince1970: 1_700_900_000)
        let fixture = LargeFolderFixture(count: 600)
        let masters = SmartScopeExtras.masters(withCopiesIn: fixture.records)
        let extras = SmartScopeExtras(mastersWithCopies: masters)
        var hits = [0, 0, 0]
        for record in fixture.records {
            let context = extras.context(for: record, isEdited: false,
                                         keywords: record.id.flatMap { fixture.keywords[$0] } ?? [], now: now)
            for (index, rules) in Self.smartRules.enumerated() {
                // Line by line, by hand, as the joins read.
                let results = rules.criteria.map { $0.matches(record, context: context) }
                var expected = results[0]
                for (criterion, result) in zip(rules.criteria.dropFirst(), results.dropFirst()) {
                    switch rules.effectiveJoin(of: criterion) {
                    case .and: expected = expected && result
                    case .or: expected = expected || result
                    case .except: expected = expected && !result
                    }
                }
                XCTAssertEqual(rules.matches(record, context: context), expected)
                if expected { hits[index] += 1 }
            }
        }
        XCTAssertTrue(hits.allSatisfy { $0 > 0 }, "\(hits)")
        // A day parsed twice is the same day, and garbage stays nil.
        XCTAssertEqual(SmartCriterion.parseDay("2023-11-10"), SmartCriterion.parseDay(" 2023-11-10 "))
        XCTAssertNil(SmartCriterion.parseDay("not a day"))
        XCTAssertNil(SmartCriterion.parseDay("not a day"))
    }

    // MARK: - Keywords

    /// The keywording field's completion list, worked out at each keystroke.
    func testKeywordCompletionAndSuggestions() throws {
        try requireTiming()
        let fixture = LargeFolderFixture()
        let library = library(fixture)
        let dictionary = KeywordDictionary(paths: fixture.dictionaryPaths)
        var suggestions: [String] = []
        let typed = "lis"
        // The Library's share of a keystroke: the folder's keywords (the app
        // merges them with the dictionary's once, KeywordDictionaryStore)
        // and the ranking over the merged list.
        let merged = Array(Set(library.availableKeywords).union(dictionary.allPaths)).sorted()
        let perKeystroke = time {
            for end in typed.indices {
                _ = library.availableKeywords
                suggestions = KeywordPath.suggestions(for: String(typed[...end]), in: merged, limit: 6)
            }
        } / Double(typed.count)
        report("keyword completion keystroke, 10k photos + \(fixture.dictionaryPaths.count) dictionary paths", perKeystroke)
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertLessThan(perKeystroke, 0.1)

        let current: Set<String> = ["Places|Portugal|Lisbon"]
        var often: [String] = []
        let chips = time { often = library.keywordsOftenUsed(with: current, limit: 8) }
        report("often-used-with chips, 10k", chips)
        XCTAssertEqual(often, referenceCooccurring(with: current, in: library.keywordIndex, limit: 8))
        XCTAssertLessThan(chips, 0.1)

        var text = ""
        let export = time(runs: 1) { text = dictionary.text }
        report("keyword dictionary text, \(fixture.dictionaryPaths.count) paths", export)
        XCTAssertEqual(text, referenceDictionaryText(dictionary.paths))
        XCTAssertLessThan(export, 0.5)
    }

    /// The smart collection sheet redraws on every keystroke in a rule,
    /// asking each row for the folder's keywords and existing values.
    func testSmartSheetRedraw() throws {
        try requireTiming()
        let library = library()
        let fields: [SmartCriterion.Field] = [.camera, .title, .folder, .keyword]
        var values: [[String]] = []
        let redraw = time {
            values = fields.map { library.collections.existingValues(for: $0) }
            _ = library.availableKeywords
            _ = library.availableKeywords
        }
        report("smart sheet values (4 rows), 10k", redraw)
        XCTAssertEqual(values[0], SmartCriterion.existingValues(for: .camera, in: library.images))
        XCTAssertLessThan(redraw, 0.25)

        let rules = Self.smartRules[0]
        var count = 0
        let matchCount = time {
            let context = library.collections.matchContexts(for: rules)
            count = library.images.filter { rules.matches($0, context: context($0)) }.count
        }
        report("smart sheet match count, 10k", matchCount)
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(matchCount, 0.25)
    }

    /// Cached keyword and value lists follow the folder.
    func testCachedListsFollowChanges() {
        let fixture = LargeFolderFixture(count: 300)
        let library = library(fixture)
        let before = library.availableKeywords
        XCTAssertFalse(before.contains("Brand|New"))
        var index = library.keywordIndex
        index[1, default: []].insert("Brand|New")
        library.keywordIndex = index
        XCTAssertTrue(library.availableKeywords.contains("Brand|New"))
        XCTAssertEqual(library.availableKeywords, Array(index.values.reduce(into: Set<String>()) { $0.formUnion($1) }).sorted())

        XCTAssertFalse(library.collections.existingValues(for: .camera).contains("Leica M11"))
        var records = library.images
        records[0].camera = "Leica M11"
        library.replaceImagesForTesting(records)
        XCTAssertTrue(library.collections.existingValues(for: .camera).contains("Leica M11"))
        var patched = library.images[1]
        patched.camera = "Hasselblad X2D"
        library.patchRecordsForTesting([patched.id!: patched])
        XCTAssertTrue(library.collections.existingValues(for: .camera).contains("Hasselblad X2D"))
        XCTAssertTrue(library.availableCameras.contains("Hasselblad X2D"))
    }

    // MARK: - References (the code as it was)

    private func referenceCooccurring(with keywords: Set<String>, in index: [Int64: Set<String>], limit: Int) -> [String] {
        var counts: [String: Int] = [:]
        for paths in index.values where !paths.isDisjoint(with: keywords) {
            for path in paths where !keywords.contains(path) { counts[path, default: 0] += 1 }
        }
        return counts.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key.localizedStandardCompare(b.key) == .orderedAscending
        }.prefix(limit).map(\.key)
    }

    private func referenceDictionaryText(_ paths: Set<String>) -> String {
        let leaves = paths.filter { path in !paths.contains { $0 != path && KeywordPath.path($0, isWithin: path) } }
        return leaves.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
            + (leaves.isEmpty ? "" : "\n")
    }
}

/// A made-up folder shaped like a few months of real shooting: two
/// cameras and four lenses, the usual ISO, aperture and shutter steps,
/// bursts, titles and captions now and then, virtual copies, ratings,
/// flags and labels, and 0 to 5 hierarchical keywords per photo from a
/// vocabulary of about 700.
struct LargeFolderFixture {
    let records: [ImageRecord]
    let keywords: [Int64: Set<String>]
    /// What a keyword dictionary built up over many folders holds.
    let dictionaryPaths: [String]

    init(count: Int = LargeFolderPerformanceTests.count) {
        let countries = ["Portugal", "Spain", "France", "Italy", "Norway", "Japan", "Chile", "Kenya"]
        let cities = ["Lisbon", "Porto", "Madrid", "Paris", "Rome", "Oslo", "Kyoto", "Santiago", "Nairobi", "Faro"]
        var vocabulary: [String] = []
        for (i, country) in countries.enumerated() {
            for j in 0..<10 { vocabulary.append("Places|\(country)|\(cities[(i + j) % cities.count]) \(j)") }
            vocabulary.append("Places|\(country)|\(cities[i % cities.count])")
        }
        for i in 0..<300 { vocabulary.append("People|Person \(i)") }
        for i in 0..<300 { vocabulary.append("Subjects|Topic \(i % 30)|Detail \(i)") }
        vocabulary.append("Places|Portugal|Lisbon")
        let isos = [64, 100, 200, 400, 800, 1600, 3200, 6400, 12800]
        let apertures = [1.4, 1.8, 2.8, 4, 5.6, 8, 11, 16]
        let shutters = [1.0 / 8000, 1.0 / 2000, 1.0 / 500, 1.0 / 125, 1.0 / 60, 1.0 / 15, 0.5, 2]
        let focals = [14.0, 24, 35, 50, 85, 135, 200, 400]
        var records: [ImageRecord] = []
        var keywords: [Int64: Set<String>] = [:]
        records.reserveCapacity(count)
        for index in 0..<count {
            var path = String(format: "2023/Day %02d/DSC_%05d.NEF", index % 30, (index * 7919) % 100_000)
            if index % 97 == 0 { path += "#vc002-0a1b2c3d" }
            let id = Int64(index + 1)
            var record = ImageRecord(id: id, relPath: path, size: 1, mtime: Int64(index % 5000),
                                     xxhash: Data(count: 8),
                                     captureTime: index % 50 == 0 ? nil : Int64(1_697_000_000 + index * 311),
                                     camera: index % 3 == 0 ? "NIKON D750" : "NIKON Z 8",
                                     rating: index % 6, flag: index % 7 == 0 ? 1 : index % 11 == 0 ? -1 : 0)
            record.lens = ["24-70mm f/2.8", "70-200mm f/2.8", "50mm f/1.4", "14-30mm f/4"][index % 4]
            record.iso = index % 40 == 0 ? nil : isos[(index / 3) % isos.count]
            record.aperture = apertures[(index / 5) % apertures.count]
            record.shutter = shutters[(index / 7) % shutters.count]
            record.focal = focals[(index / 2) % focals.count]
            record.width = index % 4 == 0 ? 4000 : 6000
            record.height = index % 4 == 0 ? 6000 : 4000
            record.label = index % 9 == 0 ? "Red" : nil
            record.title = index % 10 == 0 ? "Harbour \(index)" : nil
            record.caption = index % 13 == 0 ? "Boats at dusk, day \(index % 30)" : nil
            record.creator = index % 2 == 0 ? "Ana" : "Rui"
            records.append(record)
            let n = index % 6
            if n > 0 {
                keywords[id] = Set((0..<n).map { vocabulary[(index * 31 + $0 * 197) % vocabulary.count] })
            }
        }
        self.records = records
        self.keywords = keywords
        var dictionary = vocabulary
        for i in 0..<2_500 { dictionary.append("Archive|Year \(2000 + i % 25)|Event \(i)") }
        dictionaryPaths = dictionary
    }
}
