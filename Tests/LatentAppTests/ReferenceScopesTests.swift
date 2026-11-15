import XCTest
import PixelEngine
@testable import latent_app

/// Overlay Reference's vectorscope outline, the scope caption and the two
/// new scope settings.
@MainActor
final class ReferenceScopesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "ReferenceScopesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testOutlineMarksEdgesAndInside() {
        let n = Vectorscope.size
        var counts = [UInt32](repeating: 0, count: n * n)
        // A 5×5 block of colour in the middle, and one stray faint cell.
        for y in 60..<65 { for x in 60..<65 { counts[y * n + x] = 400 } }
        counts[10 * n + 10] = 1
        let cells: [ReferenceScopeOutline.Cell] = ReferenceScopeOutline.cells(of: Vectorscope(counts: counts, peak: 400))
        XCTAssertEqual(cells[62 * n + 62], .inside)
        XCTAssertEqual(cells[60 * n + 62], .edge)
        XCTAssertEqual(cells[64 * n + 64], .edge)
        XCTAssertEqual(cells[59 * n + 62], .empty)
        XCTAssertEqual(cells[10 * n + 10], .empty, "below the threshold")
        XCTAssertEqual(cells.filter { $0 == .inside }.count, 9)
        XCTAssertEqual(cells.filter { $0 == .edge }.count, 16)
        XCTAssertNotNil(ReferenceScopeOutline.image(of: Vectorscope(counts: counts, peak: 400)))
    }

    func testOutlineOfEmptyScopeIsEmpty() {
        let n = Vectorscope.size
        let cells: [ReferenceScopeOutline.Cell] = ReferenceScopeOutline.cells(
            of: Vectorscope(counts: [UInt32](repeating: 0, count: n * n), peak: 0))
        XCTAssertTrue(cells.allSatisfy { $0 == .empty })
    }

    func testCaption() {
        XCTAssertEqual(ScopeModeCaption.parts(maskOnly: false, maskSelected: true, overlayingReference: false), [])
        XCTAssertEqual(ScopeModeCaption.parts(maskOnly: true, maskSelected: true, overlayingReference: false),
                       ["Selected mask only"])
        XCTAssertEqual(ScopeModeCaption.parts(maskOnly: true, maskSelected: false, overlayingReference: true),
                       ["Select a mask to limit the scopes", "Reference in amber"])
    }

    func testSettingsPersistAndDefaultOff() {
        let settings = ScopeSettings(defaults: defaults)
        XCTAssertFalse(settings.selectedMaskOnly)
        XCTAssertFalse(settings.overlaysReference)
        settings.selectedMaskOnly = true
        settings.overlaysReference = true
        let again = ScopeSettings(defaults: defaults)
        XCTAssertTrue(again.selectedMaskOnly)
        XCTAssertTrue(again.overlaysReference)
    }

    func testMaskIndexNeedsTheSettingAndASelection() {
        let model = EditorModel()
        let saved = ScopeSettings.shared.selectedMaskOnly
        defer { ScopeSettings.shared.selectedMaskOnly = saved }
        ScopeSettings.shared.selectedMaskOnly = true
        XCTAssertNil(model.scopeMaskIndex, "no locals")
        model.parameters.locals = [LocalAdjustment(name: "A", shape: .whole)]
        model.selectedLocalIndex = 0
        XCTAssertEqual(model.scopeMaskIndex, 0)
        ScopeSettings.shared.selectedMaskOnly = false
        XCTAssertNil(model.scopeMaskIndex)
    }
}
