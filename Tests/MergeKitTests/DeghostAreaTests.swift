import XCTest
@testable import PixelEngine

/// The rules that give each moving area its source frame
/// (`HDRGhostAreas`), on small hand-made maps: no GPU, no raws.
final class DeghostAreaTests: XCTestCase {
    typealias Frame = HDRGhostAreas.Frame

    /// A 40 x 30 map with one moving rectangle (x 10..<30, y 5..<25),
    /// already widened: every block of it moving.
    static let width = 40, height = 30
    static func rectangle(_ x: Range<Int>, _ y: Range<Int>) -> [Bool] {
        (0..<(width * height)).map { x.contains($0 % width) && y.contains($0 / width) }
    }
    static let moving = rectangle(10..<30, 5..<25)

    /// A frame usable and well exposed everywhere, except `usable` and
    /// `exposed` where `override` says.
    static func frame(_ index: Int, ev: Double, override: (Int) -> (usable: UInt8, exposed: UInt8)? = { _ in nil })
    -> Frame {
        let values = (0..<(width * height)).map { override($0) ?? (255, 255) }
        return Frame(index: index, relativeEV: ev, usable: values.map(\.usable), exposed: values.map(\.exposed))
    }

    static func areas(_ frames: [Frame], reference: Int = 1, moving: [Bool] = moving) -> HDRGhostAreas {
        HDRGhostAreas(width: width, height: height, moving: moving, widened: moving, frames: frames,
                      referenceIndex: reference)
    }

    /// A dark coat in the middle of the area is crushed in the reference,
    /// so the brightest frame sees those blocks better; the whole area still
    /// comes from the reference, not a patchwork.
    func testAWholeAreaComesFromTheReferenceDespiteADarkPatch() {
        let coat = Self.rectangle(16..<24, 10..<20)
        let frames = [
            Self.frame(0, ev: 0),
            Self.frame(1, ev: -1) { coat[$0] ? (255, 20) : nil },
            Self.frame(2, ev: -2) { coat[$0] ? (255, 0) : nil },
        ]
        let areas = Self.areas(frames)
        XCTAssertEqual(areas.areaCount, 1)
        for i in 0..<(Self.width * Self.height) {
            XCTAssertEqual(areas.sources[i], Self.moving[i] ? 1 : -1, "block \(i)")
        }
    }

    /// Where the reference is badly clipped over most of the area, the
    /// frame that sees the area best takes all of it.
    func testAMostlyClippedReferenceHandsTheAreaOver() {
        let frames = [
            Self.frame(0, ev: 0) { _ in (0, 255) },
            Self.frame(1, ev: -1) { Self.moving[$0] && $0 % Self.width < 26 ? (0, 255) : nil },
            Self.frame(2, ev: -2),
        ]
        let areas = Self.areas(frames)
        XCTAssertEqual(Set(areas.sources.filter { $0 >= 0 }), [2])
    }

    /// Blocks the source is clipped in go to the nearest darker frame that
    /// isn't clipped there, never to a brighter one (which, unclipped where
    /// the source is clipped, shows something that moved); where every
    /// darker frame is clipped too, to the darkest.
    func testClippedBlocksGoToTheNearestDarkerFrame() {
        let glint = Self.rectangle(12..<14, 8..<10), glare = Self.rectangle(20..<22, 8..<10)
        let frames = [
            Self.frame(0, ev: 0),
            Self.frame(1, ev: -1) { glint[$0] || glare[$0] ? (0, 255) : nil },
            Self.frame(2, ev: -2) { glare[$0] ? (0, 255) : nil },
            Self.frame(3, ev: -3) { glare[$0] ? (40, 255) : nil },
        ]
        let areas = Self.areas(frames)
        for i in 0..<(Self.width * Self.height) where Self.moving[i] {
            XCTAssertEqual(areas.sources[i], glint[i] ? 2 : glare[i] ? 3 : 1, "block \(i)")
        }
    }

    /// Three blocks of movement are noise: no area.
    func testTinyAreasAreDropped() {
        let speck = Self.rectangle(5..<8, 3..<4)
        let areas = Self.areas([Self.frame(0, ev: 0), Self.frame(1, ev: -1)], moving: speck)
        XCTAssertEqual(areas.areaCount, 0)
        XCTAssertTrue(areas.sources.allSatisfy { $0 == -1 })
    }

    /// Separate areas choose separately.
    func testSeparateAreasChooseTheirOwnSources() {
        let left = Self.rectangle(2..<10, 5..<15), right = Self.rectangle(28..<36, 5..<15)
        let both = zip(left, right).map { $0 || $1 }
        let frames = [
            Self.frame(0, ev: 0) { _ in (0, 255) },
            Self.frame(1, ev: -1) { left[$0] ? (0, 255) : nil },
            Self.frame(2, ev: -2),
        ]
        let areas = Self.areas(frames, moving: both)
        XCTAssertEqual(areas.areaCount, 2)
        XCTAssertEqual(Set((0..<both.count).filter { left[$0] }.map { areas.sources[$0] }), [2])
        XCTAssertEqual(Set((0..<both.count).filter { right[$0] }.map { areas.sources[$0] }), [1])
    }

    /// The box sum clamps its window to the map.
    func testBoxSum() {
        let sums = HDRGhostAreas.boxSum([Double](repeating: 1, count: 20), width: 5, height: 4, radius: 1)
        XCTAssertEqual(sums[0], 4)
        XCTAssertEqual(sums[1], 6)
        XCTAssertEqual(sums[6], 9)
    }
}
