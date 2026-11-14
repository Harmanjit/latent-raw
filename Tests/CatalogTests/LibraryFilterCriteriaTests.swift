import XCTest
@testable import Catalog

/// The filter bar's newer criteria (LibraryFilter+Criteria.swift), presets'
/// JSON, the Ranges histograms, Select Unedited and the grid marks modes.
final class LibraryFilterCriteriaTests: XCTestCase {
    private func record(_ id: Int64, _ path: String, rating: Int = 0, label: String? = nil,
                        camera: String? = nil, lens: String? = nil, iso: Int? = nil, shutter: Double? = nil,
                        aperture: Double? = nil, focal: Double? = nil, captured: Int64? = nil) -> ImageRecord {
        ImageRecord(id: id, relPath: path, preservedName: nil, size: 1, mtime: 0,
                    xxhash: Data(count: 8), captureTime: captured, camera: camera, lens: lens,
                    lensId: nil, iso: iso, shutter: shutter, aperture: aperture, focal: focal,
                    width: nil, height: nil, orientation: nil, rating: rating, label: label,
                    flag: 0, sidecarMtime: nil, thumbKey: nil)
    }

    private func passing(_ filter: LibraryFilter, _ records: [ImageRecord],
                         keywords: [Int64: Set<String>] = [:], edited: Set<Int64> = [],
                         context: LibraryFilterContext? = nil) -> [Int64] {
        let context = context ?? LibraryFilterContext(filter: filter, images: records, pairedCompanions: [:])
        return records.filter {
            filter.matches($0, isEdited: edited.contains($0.id!), keywords: keywords[$0.id!] ?? [], context: context)
        }.compactMap(\.id)
    }

    // MARK: - Search

    func testSearchQueryParsesWordsPhrasesAndExclusions() {
        let query = SearchQuery(#"  Paris "Eiffel Tower" -night - Ünï  "#)
        XCTAssertEqual(query.included, ["paris", "eiffel tower", "ünï"])
        XCTAssertEqual(query.excluded, ["night"])
        XCTAssertTrue(SearchQuery("   ").isEmpty)
        XCTAssertTrue(SearchQuery("\"\" -").isEmpty, "empty phrases and a lone minus are no terms")
        XCTAssertEqual(SearchQuery(#"-"blue hour""#).excluded, ["blue hour"])
    }

    func testAllFieldsSearchLooksEverywhereAndCombinesTerms() {
        var a = record(1, "Trip/DSC_0001.NEF", camera: "NIKON D750", lens: "AF-S 50mm f/1.8G")
        a.creator = "Ann Smith"
        var b = record(2, "Trip/DSC_0002.NEF", camera: "SONY A7")
        b.copyright = "© Bob Jones"
        b.caption = "Eiffel Tower at night"
        let c = record(3, "Home/IMG_7.JPG", camera: "NIKON Z 8")
        let records = [a, b, c]
        let keywords: [Int64: Set<String>] = [3: ["Places|France|Paris"]]

        var f = LibraryFilter()
        f.textScope = .everything
        f.text = "nikon"
        XCTAssertEqual(passing(f, records, keywords: keywords), [1, 3], "camera, case-insensitive")
        f.text = "trip nikon"
        XCTAssertEqual(passing(f, records, keywords: keywords), [1], "terms are ANDed, path counts")
        f.text = "nikon -trip"
        XCTAssertEqual(passing(f, records, keywords: keywords), [3])
        f.text = "france"
        XCTAssertEqual(passing(f, records, keywords: keywords), [3], "keywords")
        f.text = "\"tower at night\""
        XCTAssertEqual(passing(f, records, keywords: keywords), [2], "a quoted phrase matches as one")
        f.text = "\"tower night\""
        XCTAssertEqual(passing(f, records, keywords: keywords), [])
        f.text = "smith 50mm"
        XCTAssertEqual(passing(f, records, keywords: keywords), [1], "creator and lens")
        f.text = "jones"
        XCTAssertEqual(passing(f, records, keywords: keywords), [2], "copyright")
        // Without a context the query is parsed on the spot, same answer.
        XCTAssertTrue(f.matches(b, isEdited: false, keywords: []))
        XCTAssertTrue(f.readsKeywords)
    }

    func testNamesScopeIsTheSearchAsBefore() {
        let records = [record(1, "Day/HSB_2615.NEF", camera: "NIKON"), record(2, "Day/DSC 1.NEF")]
        var f = LibraryFilter()
        f.text = "nikon"
        XCTAssertEqual(passing(f, records), [], "the camera isn't searched by default")
        f.text = "dsc 1"
        XCTAssertEqual(passing(f, records), [2], "the whole text is one piece")
        XCTAssertFalse(f.readsKeywords)
    }

    // MARK: - Labels, rating, edited, keywords

    func testExcludedLabels() {
        let records = [record(1, "a", label: "Red"), record(2, "b", label: "Blue"), record(3, "c"),
                       record(4, "d", label: "Approved")]
        var f = LibraryFilter()
        f.excludedLabels = [.color(.red)]
        XCTAssertTrue(f.isActive)
        XCTAssertEqual(passing(f, records), [2, 3, 4])
        f.excludedLabels = [.color(.red), .none]
        XCTAssertEqual(passing(f, records), [2, 4])
        f.labels = [.color(.blue), .custom]
        XCTAssertEqual(passing(f, records), [2, 4], "any included label, and no excluded one")
        f.excludedLabels = [.custom]
        XCTAssertEqual(passing(f, records), [2])
    }

    func testRatingOperators() {
        let records = (0...5).map { record(Int64($0 + 1), "r\($0)", rating: $0) }
        var f = LibraryFilter()
        f.minRating = 3
        XCTAssertEqual(passing(f, records), [4, 5, 6], "at least, the default")
        f.ratingOperator = .exactly
        XCTAssertEqual(passing(f, records), [4])
        f.minRating = 0
        XCTAssertTrue(f.isActive)
        XCTAssertEqual(passing(f, records), [1], "exactly no stars")
        f.ratingOperator = .atMost
        f.maxRating = 2
        XCTAssertEqual(passing(f, records), [1, 2, 3])
        f.maxRating = 5
        XCTAssertFalse(f.isActive, "at most five hides nothing")
        f.ratingOperator = .between
        f.minRating = 4
        f.maxRating = 2
        XCTAssertEqual(passing(f, records), [3, 4, 5], "ends in either order")
    }

    func testUneditedAndNoKeywords() {
        let records = [record(1, "a"), record(2, "b"), record(3, "c")]
        var f = LibraryFilter()
        f.uneditedOnly = true
        XCTAssertTrue(f.readsEdits)
        XCTAssertEqual(passing(f, records, edited: [2]), [1, 3])
        f = LibraryFilter()
        f.noKeywords = true
        XCTAssertTrue(f.readsKeywords)
        XCTAssertEqual(passing(f, records, keywords: [1: ["x"], 3: []]), [2, 3])
    }

    // MARK: - Ranges, dates, kinds

    func testShootingRangesHideMissingValuesOnlyWhileSet() {
        let records = [record(1, "a", iso: 100, shutter: 1.0 / 250, aperture: 2.8, focal: 35),
                       record(2, "b", iso: 3200, shutter: 2, aperture: 8, focal: 200),
                       record(3, "c")]
        var f = LibraryFilter()
        XCTAssertEqual(passing(f, records), [1, 2, 3])
        f.isoRange = 50...800
        XCTAssertEqual(passing(f, records), [1])
        f = LibraryFilter(); f.focalRange = 100...300
        XCTAssertEqual(passing(f, records), [2])
        f = LibraryFilter(); f.apertureRange = 1.4...4
        XCTAssertEqual(passing(f, records), [1])
        f = LibraryFilter(); f.shutterRange = 1...30
        XCTAssertEqual(passing(f, records), [2])
    }

    func testCaptureDateRange() {
        let day: Int64 = 1_700_000_000
        let records = [record(1, "a", captured: day), record(2, "b", captured: day + 86_400 * 3), record(3, "c")]
        var f = LibraryFilter()
        let start = Date(timeIntervalSince1970: TimeInterval(day - 10))
        f.captureDateRange = start...start.addingTimeInterval(86_400)
        XCTAssertEqual(passing(f, records), [1])
        f.captureDateRange = nil
        XCTAssertEqual(passing(f, records), [1, 2, 3], "undated photos come back with no range")
    }

    func testQuickDateRangesAndWholeDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // Tue 14 Nov 2023, 22:13 UTC
        let today = CaptureDateQuickRange.today.range(now: now, calendar: calendar)
        XCTAssertEqual(today.lowerBound, calendar.startOfDay(for: now))
        XCTAssertTrue(today.contains(now))
        XCTAssertLessThan(today.upperBound.timeIntervalSince(today.lowerBound), 86_400)
        let week = CaptureDateQuickRange.last7Days.range(now: now, calendar: calendar)
        XCTAssertEqual(calendar.dateComponents([.day], from: week.lowerBound, to: today.lowerBound).day, 6)
        let month = CaptureDateQuickRange.thisMonth.range(now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: month.lowerBound), 1)
        let year = CaptureDateQuickRange.thisYear.range(now: now, calendar: calendar)
        XCTAssertEqual(calendar.component(.month, from: year.lowerBound), 1)
        let days = CaptureDateQuickRange.days(from: now, to: week.lowerBound, calendar: calendar)
        XCTAssertEqual(days.lowerBound, week.lowerBound, "either order")
        XCTAssertEqual(days.upperBound, today.upperBound)
    }

    func testFileKind() {
        let raw = record(1, "a.NEF"), dng = record(2, "b.dng"), jpeg = record(3, "c.jpg"), pairJPEG = record(4, "a.JPG")
        let records = [raw, dng, jpeg, pairJPEG]
        var f = LibraryFilter()
        f.fileKind = .raw
        XCTAssertEqual(passing(f, records), [1, 2], "DNG counts as raw, as the File type sort groups it")
        f.fileKind = .notRaw
        XCTAssertEqual(passing(f, records), [3, 4])
        f.fileKind = .rawJPEGPair
        let context = LibraryFilterContext(filter: f, images: records, pairedCompanions: [1: [pairJPEG]])
        XCTAssertEqual(passing(f, records, context: context), [1, 4])
    }

    func testCopyKind() {
        let master = record(1, "Day/DSC_1.NEF")
        let copy = record(2, VirtualCopy.relPath(master: master.relPath, key: .init(number: 2, token: "0a1b2c3d")))
        let lonely = record(3, "Day/DSC_2.NEF")
        let records = [master, copy, lonely]
        var f = LibraryFilter()
        f.copyKind = .masters
        XCTAssertEqual(passing(f, records), [1, 3])
        f.copyKind = .virtualCopies
        XCTAssertEqual(passing(f, records), [2])
        f.copyKind = .hasVirtualCopies
        XCTAssertEqual(passing(f, records), [1])
    }

    func testNewCriteriaDependOnTheirFields() {
        let old = record(1, "a", rating: 1, iso: 100)
        var new = old
        new.iso = 200
        var f = LibraryFilter()
        XCTAssertFalse(f.dependsOnChange(from: old, to: new))
        f.isoRange = 0...150
        XCTAssertTrue(f.dependsOnChange(from: old, to: new))
        f = LibraryFilter(); f.ratingOperator = .exactly
        new = old; new.rating = 2
        XCTAssertTrue(f.dependsOnChange(from: old, to: new))
    }

    // MARK: - Presets' JSON

    func testFilterRoundTripsAndOldJSONReadsAsAtLeast() throws {
        var f = LibraryFilter()
        f.minRating = 2
        f.maxRating = 4
        f.ratingOperator = .between
        f.flags = [.picked, .rejected]
        f.labels = [.color(.red), .none]
        f.excludedLabels = [.custom]
        f.camera = "NIKON D750"
        f.text = "paris -night"
        f.textScope = .everything
        f.isoRange = 100...800
        f.captureDateRange = Date(timeIntervalSince1970: 0)...Date(timeIntervalSince1970: 86_400)
        f.fileKind = .raw
        f.copyKind = .masters
        f.uneditedOnly = true
        f.noKeywords = true
        f.recentlyAddedIDs = [1, 2]
        let data = try JSONEncoder().encode(f)
        var expected = f
        expected.recentlyAddedIDs = nil
        XCTAssertEqual(try JSONDecoder().decode(LibraryFilter.self, from: data), expected,
                       "everything but the Recently Added list survives")

        XCTAssertEqual(String(decoding: try JSONEncoder().encode(LibraryFilter()), as: UTF8.self), "{}")
        let old = try JSONDecoder().decode(LibraryFilter.self, from: Data(#"{"minRating":3,"editedOnly":true}"#.utf8))
        XCTAssertEqual(old.ratingOperator, .atLeast)
        XCTAssertEqual(old.minRating, 3)
        XCTAssertTrue(old.editedOnly)
    }

    // MARK: - Histograms

    func testRangeHistogramBucketsAndRanges() {
        let h = RangeHistogram(values: [100, 250, 500, 1000, 1600, 0], bucketCount: 4)
        XCTAssertEqual(h.lower, 100)
        XCTAssertEqual(h.upper, 1600)
        XCTAssertEqual(h.counts.reduce(0, +), 5, "zero is left out on a log scale")
        XCTAssertEqual(h.counts, [1, 1, 1, 2])
        XCTAssertEqual(h.edge(2), 400, accuracy: 0.001)
        XCTAssertNil(h.range(buckets: 0...3), "every bucket is no constraint")
        let range = h.range(buckets: 1...2)!
        XCTAssertEqual(range.lowerBound, 200, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 800, accuracy: 0.001)
        XCTAssertEqual(h.buckets(for: range), 1...2)
        XCTAssertEqual(h.buckets(for: nil), 0...3)

        let single = RangeHistogram(values: [50, 50])
        XCTAssertEqual(single.counts, [2])
        XCTAssertTrue(RangeHistogram(values: []).isEmpty)
        let linear = RangeHistogram(values: [0, 10], bucketCount: 2, logarithmic: false)
        XCTAssertEqual(linear.counts, [1, 1])
        XCTAssertEqual(linear.edge(1), 5)
    }

    // MARK: - Select Unedited

    func testSelectUnedited() {
        let visible = [record(1, "a"), record(2, "b"), record(3, "c")]
        XCTAssertEqual(CullingSelection.unedited.selection(in: visible, current: [1], edited: [2]), [1, 3])
        XCTAssertEqual(CullingSelection.unedited.selection(in: visible, current: []), [1, 2, 3])
    }

    // MARK: - Grid marks

    func testGridMarksModes() {
        XCTAssertEqual(GridMarksMode.always.visibility(hovered: false), .all, "the default is the grid as it was")
        XCTAssertEqual(GridMarksMode.onHover.visibility(hovered: false), .none)
        XCTAssertEqual(GridMarksMode.onHover.visibility(hovered: true), .all)
        let minimal = GridMarksMode.minimal.visibility(hovered: true)
        XCTAssertTrue(minimal.flagBadge && minimal.labelDot)
        XCTAssertFalse(minimal.name || minimal.stars || minimal.editedBadge || minimal.tagDots || minimal.keywordBadge)
        XCTAssertTrue(GridMarksMode.extended.visibility(hovered: false).infoLine)
        XCTAssertFalse(GridMarkVisibility.all.infoLine)
    }

    func testKeywordBadgeSitsBetweenTheBadgesAndTheLabel() {
        for side in [80.0, 160, 256] {
            let layout = ThumbnailGridLayout(side: side)
            XCTAssertEqual(layout.flagBadgeFrame(hasLabel: true, hasKeywords: false), layout.flagBadgeFrame(hasLabel: true))
            XCTAssertEqual(layout.flagBadgeFrame(hasLabel: false, hasKeywords: false), layout.flagBadgeFrame(hasLabel: false))
            for hasLabel in [false, true] {
                let badge = layout.keywordBadgeFrame(hasLabel: hasLabel)
                let flags = layout.flagBadgeFrame(hasLabel: hasLabel, hasKeywords: true)
                XCTAssertLessThanOrEqual(flags.maxX, badge.minX)
                XCTAssertLessThanOrEqual(badge.maxX, hasLabel ? layout.labelDotFrame.minX : layout.starsFrame.minX)
                XCTAssertEqual(badge.minY, layout.badgeFrame.minY)
            }
            let image = layout.thumbnailArea
            let line = ThumbnailGridLayout.infoLineFrame(inImageFrame: image)
            XCTAssertEqual(line.maxY, image.maxY)
            XCTAssertEqual(line.width, image.width)
        }
    }
}
