import XCTest
import PixelEngine
@testable import latent_app

/// The extra scopes, the vectorscope's guides, the picker settings and
/// the pinned colour samples.
@MainActor
final class ScopeGuidesTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "ScopeGuidesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testScopeKindsSplitBetweenSegmentsAndMenu() {
        XCTAssertEqual(ScopeKind.primary, [.histogram, .waveform, .vectorscope])
        XCTAssertEqual(Set(ScopeKind.primary + ScopeKind.more), Set(ScopeKind.allCases))
        XCTAssertTrue(Set(ScopeKind.primary).isDisjoint(with: ScopeKind.more))
    }

    func testHarmonyAngles() {
        XCTAssertEqual(HarmonyGuide.none.angles(base: 40), [])
        XCTAssertEqual(HarmonyGuide.complementary.angles(base: 300), [300, 120])
        XCTAssertEqual(HarmonyGuide.triad.angles(base: 0), [0, 120, 240])
        XCTAssertEqual(HarmonyGuide.splitComplementary.angles(base: 10), [10, 160, 220])
        XCTAssertEqual(HarmonyGuide.tetrad.angles(base: 0), [0, 60, 180, 240])
        XCTAssertEqual(HarmonyGuide.analogous.angles(base: 10), [340, 10, 40])
    }

    func testGeometryRoundTrips() {
        let rect = CGRect(x: 10, y: 20, width: 100, height: 100)
        for a in stride(from: 0.0, to: 360, by: 37) {
            let p = VectorscopeGeometry.point(angle: a, fraction: 0.8, in: rect)
            XCTAssertEqual(VectorscopeGeometry.angle(of: p, in: rect), a, accuracy: 1e-6)
        }
        // Up is 90°: Cr increases upward.
        XCTAssertEqual(VectorscopeGeometry.angle(of: CGPoint(x: 60, y: 25), in: rect), 90, accuracy: 1e-6)
        XCTAssertEqual(VectorscopeGeometry.normalised(-30), 330)
    }

    func testSettingsDefaultAndPersist() {
        let s = ScopeSettings(defaults: defaults)
        XCTAssertFalse(s.skinToneLine)
        XCTAssertEqual(s.harmony, HarmonyGuide.none)
        XCTAssertEqual(s.sampleSize, .point)
        XCTAssertEqual(s.readoutSpace, .standard)
        XCTAssertTrue(s.plotsSamples)
        s.skinToneLine = true
        s.harmony = .triad
        s.harmonyAngle = 200
        s.sampleSize = .fifteen
        s.readoutSpace = .lch
        let again = ScopeSettings(defaults: defaults)
        XCTAssertTrue(again.skinToneLine)
        XCTAssertEqual(again.harmony, .triad)
        XCTAssertEqual(again.harmonyAngle, 200)
        XCTAssertEqual(again.sampleSize, .fifteen)
        XCTAssertEqual(again.readoutSpace, .lch)
    }

    func testSamplesLimitAndImage() {
        let samples = ColourSamples()
        let a = URL(fileURLWithPath: "/a.nef"), b = URL(fileURLWithPath: "/b.nef")
        for i in 0..<ColourSamples.limit {
            XCTAssertTrue(samples.pin(at: CGPoint(x: i, y: i), size: .point, value: nil, url: a))
        }
        XCTAssertFalse(samples.pin(at: .zero, size: .point, value: nil, url: a))
        XCTAssertEqual(samples.samples(for: a).map(\.id), Array(1...8))
        XCTAssertEqual(samples.samples(for: b), [])
        samples.remove(id: 3)
        XCTAssertEqual(samples.samples(for: a).count, 7)
        XCTAssertTrue(samples.pin(at: .zero, size: .five, value: nil, url: b))
        XCTAssertEqual(samples.samples(for: a), [])
        XCTAssertEqual(samples.samples(for: b).map(\.id), [1])
    }

    func testSampleValuesUpdate() throws {
        let samples = ColourSamples()
        let url = URL(fileURLWithPath: "/a.nef")
        samples.pin(at: .zero, size: .point, value: nil, url: url)
        let v = try XCTUnwrap(PixelAreaStatistics(pixels: [SIMD3(0.5, 0.5, 0.5)]))
        samples.update(values: [1: v])
        XCTAssertEqual(samples.samples(for: url).first?.value, v)
    }

    func testReadoutLinesInAreaMode() throws {
        let s = ScopeSettings(defaults: defaults)
        let area = try XCTUnwrap(PixelAreaStatistics(pixels: [SIMD3(0, 0, 0), SIMD3(1, 1, 1)]))
        s.sampleSize = .five
        s.readoutSpace = .rgb255
        let text = try XCTUnwrap(PixelReadoutLines.text(readout: area.mean, area: area, settings: s))
        XCTAssertTrue(text.hasPrefix("x̄ R "), text)
        XCTAssertTrue(text.contains("min R 0  G 0  B 0  max R 255  G 255  B 255"), text)
        s.sampleSize = .point
        s.readoutSpace = .standard
        XCTAssertEqual(PixelReadoutLines.text(readout: area.mean, area: area, settings: s), area.mean.text(in: .standard))
    }
}
