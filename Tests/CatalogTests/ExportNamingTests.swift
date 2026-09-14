import XCTest
@testable import Catalog

final class ExportNamingTests: XCTestCase {
    private func record(_ name: String, captured: Int64? = 1_789_321_260, camera: String? = "Nikon D750",
                        rating: Int = 3) -> ImageRecord {
        ImageRecord(id: 1, relPath: name, preservedName: nil, size: 1, mtime: 1_700_000_000_000,
                    xxhash: Data(count: 8), captureTime: captured, camera: camera, lens: nil, lensId: nil,
                    iso: nil, shutter: nil, aperture: nil, focal: nil, width: nil, height: nil,
                    orientation: nil, rating: rating, label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil)
    }

    private let utc = TimeZone(identifier: "UTC")!

    func testTokens() {
        let r = record("Day 2/DSC_0042.NEF")
        let ctx = ExportNaming.Context(index: 4, start: 10, padding: 3, catalogName: "Shoot")
        XCTAssertEqual(ExportNaming.fileName(template: "{name}", record: r, context: ctx, timeZone: utc), "DSC_0042")
        XCTAssertEqual(ExportNaming.fileName(template: "{date}-{seq}", record: r, context: ctx, timeZone: utc), "2026-09-13-014")
        XCTAssertEqual(ExportNaming.fileName(template: "{Camera}_{rating}star", record: r, context: ctx, timeZone: utc),
                       "NikonD750_3star", "tokens are case-insensitive")
        XCTAssertEqual(ExportNaming.fileName(template: "{folder}/{name}", record: r, context: ctx, timeZone: utc),
                       "Day 2_DSC_0042", "slashes never survive")
        XCTAssertEqual(ExportNaming.fileName(template: "{time}", record: r, context: ctx, timeZone: utc), "174100")
        // Root-level image: folder is the catalog name.
        XCTAssertEqual(ExportNaming.fileName(template: "{folder}", record: record("A.NEF"), context: ctx, timeZone: utc), "Shoot")
    }

    func testDateAndTimeFormats() {
        let r = record("DSC_0042.NEF")
        let ctx = ExportNaming.Context(index: 0)
        XCTAssertEqual(ExportNaming.fileName(template: "{date:yyyyMMdd}_{name}", record: r, context: ctx, timeZone: utc),
                       "20260913_DSC_0042")
        XCTAssertEqual(ExportNaming.fileName(template: "{DATE:yy.MM}-{time:HH.mm}", record: r, context: ctx, timeZone: utc),
                       "26.09-17.41")
        // A format with a slash can't make a subfolder.
        XCTAssertEqual(ExportNaming.fileName(template: "{date:yyyy/MM}", record: r, context: ctx, timeZone: utc), "2026_09")
        // The file date when the capture time is unknown.
        XCTAssertEqual(ExportNaming.fileName(template: "{date}", record: record("A.NEF", captured: nil),
                                             context: ctx, timeZone: utc), "2023-11-14")
    }

    /// Names must not depend on the Mac's region: the formatters are fixed
    /// to POSIX and Gregorian, so a Buddhist or Japanese calendar or
    /// Arabic-Indic digits never reach a file name.
    func testDatesIgnoreTheUsersLocaleAndCalendar() {
        let formatter = ExportNaming.posixFormatter("yyyy", timeZone: utc)
        XCTAssertEqual(formatter.locale.identifier, "en_US_POSIX")
        XCTAssertEqual(formatter.calendar.identifier, .gregorian)
        // What an unfixed formatter does in such a region, for contrast.
        let thai = DateFormatter()
        thai.locale = Locale(identifier: "th_TH@calendar=buddhist")
        thai.calendar = Calendar(identifier: .buddhist)
        thai.timeZone = utc
        thai.dateFormat = "yyyy"
        let date = Date(timeIntervalSince1970: 1_789_321_260)
        XCTAssertEqual(thai.string(from: date), "2569")
        XCTAssertEqual(formatter.string(from: date), "2026")
        XCTAssertEqual(ExportNaming.dateFolderName(for: record("A.NEF"), timeZone: utc), "2026-09-13")
    }

    func testUnknownTokensStayVisibleAndAreReported() {
        let r = record("IMG.NEF")
        let ctx = ExportNaming.Context(index: 0)
        XCTAssertEqual(ExportNaming.unknownTokens(in: "{nmae}-{seq}-{Date:}-{name:x}-{}"),
                       ["{nmae}", "{Date:}", "{name:x}", "{}"])
        XCTAssertEqual(ExportNaming.fileName(template: "{nmae}-{seq}", record: r, context: ctx), "{nmae}-001")
        XCTAssertEqual(ExportNaming.unknownTokens(in: "{name}_{date:yyyy}_{time:HH}"), [])
        // Unpaired braces are text, and "{{name}" is a brace then a token.
        XCTAssertEqual(ExportNaming.unknownTokens(in: "a{b {{name} c}"), [])
        XCTAssertEqual(ExportNaming.fileName(template: "a{b {{name} c}", record: r, context: ctx), "a{b {IMG c}")
    }

    func testSequenceStepAndPadding() {
        let r = record("IMG.NEF")
        func seq(_ index: Int, start: Int = 1, step: Int = 1, padding: Int = 3) -> String {
            ExportNaming.fileName(template: "{seq}", record: r,
                                  context: .init(index: index, start: start, padding: padding, step: step))
        }
        XCTAssertEqual(seq(0), "001")
        XCTAssertEqual(seq(3, start: 10, step: 10), "040")
        XCTAssertEqual(seq(2, start: 0, step: -5, padding: 2), "-10")
        XCTAssertEqual(seq(0, start: 12345, padding: 3), "12345")
        XCTAssertEqual(seq(Int.max, step: 2), "000", "an overflow gives zero, not a crash")
    }

    func testLetterCase() {
        let r = record("Day 2/DSC_0042.NEF")
        XCTAssertEqual(ExportNaming.fileName(template: "{name}-{camera}", record: r,
                                             context: .init(index: 0, letterCase: .lower)), "dsc_0042-nikond750")
        XCTAssertEqual(ExportNaming.fileName(template: "{folder}", record: r,
                                             context: .init(index: 0, letterCase: .upper)), "DAY 2")
    }

    func testEmptyOrBadTemplateFallsBackToTheName() {
        let r = record("IMG.NEF")
        let ctx = ExportNaming.Context(index: 0)
        XCTAssertEqual(ExportNaming.fileName(template: "", record: r, context: ctx), "IMG")
        XCTAssertEqual(ExportNaming.fileName(template: "///", record: r, context: ctx), "___")
        XCTAssertEqual(ExportNaming.fileName(template: "   ", record: r, context: ctx), "IMG")
        XCTAssertEqual(ExportNaming.sanitized("..hidden:name"), "hidden_name")
    }

    /// A name longer than a file name may be is cut by whole characters,
    /// leaving room for a collision number and the extension.
    func testLongNamesAreCappedInBytes() {
        let long = String(repeating: "日", count: 100) // 300 bytes
        let stem = ExportNaming.fileName(template: long, record: record("IMG.NEF"), context: .init(index: 0))
        XCTAssertLessThanOrEqual(stem.utf8.count, ExportNaming.maxStemBytes)
        XCTAssertEqual(stem, String(repeating: "日", count: 80))
        XCTAssertLessThanOrEqual((ExportNaming.numbered(stem + ".heic", 99_999)).utf8.count, 255)
    }

    func testNumbering() {
        XCTAssertEqual(ExportNaming.numbered("a.jpg", 2), "a-2.jpg")
        XCTAssertEqual(ExportNaming.numbered("a.b.tif", 1), "a.b-1.tif")
        XCTAssertEqual(ExportNaming.numbered("noext", 3), "noext-3")
    }
}
