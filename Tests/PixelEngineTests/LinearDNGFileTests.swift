import XCTest
import IOSurface
@testable import RawCore

/// Opening linear DNGs through `RawFile`: the pixels, the metadata, the
/// merge recipe, and the app's side of the decoder service's reply.
///
/// Tests run outside an app bundle, so `RawFile(path:)` decodes in this
/// process. The service's own code path is the same `RawFile` initializer
/// run on the descriptor it is handed; what differs on the app's side is
/// adopting the reply, which `testServiceReplyIsAdoptedAsALinearPlane`
/// covers by feeding it a reply built from a real decode. (The service
/// itself is exercised by `latent-cli render` in a --dev app bundle.)
final class LinearDNGFileTests: XCTestCase {
    private func open(_ name: String, metadataOnly: Bool = false) throws -> RawFile {
        try RawFile(path: LinearFixtures.path(name), metadataOnly: metadataOnly)
    }

    // MARK: - Pixels

    /// A merge result's pixels, bit for bit.
    func testMergeFixturePixelsAreBitExact() throws {
        let file = try open(LinearFixtures.mergeHDR)
        XCTAssertEqual(file.summary.sourceKind, .linearRGB)
        XCTAssertEqual(file.summary.cfaPattern, .linearRGB)
        XCTAssertNil(file.sensorPlane)
        let plane = try XCTUnwrap(file.linearPlane)
        XCTAssertEqual(plane.width, 64)
        XCTAssertEqual(plane.height, 48)
        try assertPlane(plane) { x, y in LinearFixtures.pattern64x48(x: x, y: y) }
    }

    /// The merge contract's layout, 512 px uncompressed tiles, bit for bit.
    func testContractTileLayoutPixelsAreBitExact() throws {
        let file = try open(LinearFixtures.tiles512)
        let plane = try XCTUnwrap(file.linearPlane)
        XCTAssertEqual(plane.width, 600)
        XCTAssertEqual(plane.height, 512)
        try assertPlane(plane) { x, y in LinearFixtures.ramp(x: x, y: y) }
    }

    /// Deflate-compressed tiles over several tiles, bit for bit.
    func testCompressedTiledFixturePixelsAreBitExact() throws {
        let file = try open(LinearFixtures.ramp)
        let plane = try XCTUnwrap(file.linearPlane)
        XCTAssertEqual(plane.width, 1200)
        XCTAssertEqual(plane.height, 800)
        try assertPlane(plane) { x, y in LinearFixtures.ramp(x: x, y: y) }
    }

    /// NaN and negative values never reach the pipeline.
    func testPlaneCleansValuesTheContractForbids() throws {
        let file = try open(LinearFixtures.plain)
        let plane = try XCTUnwrap(file.linearPlane)
        let stored = Array(plane.samples.prefix(8))
        // Pixel 0: R G B A, pixel 1: R G B A.
        let got = [stored[0], stored[1], stored[2], stored[4], stored[5], stored[6]]
        XCTAssertEqual(got.map(\.bitPattern), LinearFixtures.plainSpecialsCleaned.map(\.bitPattern))
        XCTAssertEqual(stored[3], 1)
        XCTAssertEqual(stored[7], 1)
        // And the rest is untouched.
        try assertPlane(plane, skippingFirst: 2) { x, y in LinearFixtures.pattern64x48(x: x, y: y) }
    }

    /// A 16-bit integer LinearRaw DNG, as other converters write: each
    /// channel's black subtracted and divided by white minus that black.
    func testIntegerLinearDNGIsScaledByItsChannelBlackAndWhite() throws {
        let file = try open(LinearFixtures.integer16)
        let summary = file.summary
        XCTAssertEqual(summary.sourceKind, .linearRGB)
        XCTAssertEqual(summary.whiteLevel, 16383)
        let black = summary.channelBlackLevels
        XCTAssertEqual([black.x, black.y, black.z], [100, 200, 300])
        let plane = try XCTUnwrap(file.linearPlane)
        let samples = plane.samples
        for y in 0..<48 {
            for x in 0..<64 {
                let stored = LinearFixtures.integer16Pattern(x: x, y: y)
                let values = [stored.0, stored.1, stored.2]
                for c in 0..<3 {
                    let expected = Float16(max(0, (Float(values[c]) - black[c]) / (16383 - black[c])))
                    XCTAssertEqual(samples[(y * 64 + x) * 4 + c], expected, "(\(x), \(y)) channel \(c)")
                }
            }
        }
        // The largest stored sample: green 200 + 47 x 300 on the bottom row.
        XCTAssertEqual(summary.dataMaximum, 14300)
    }

    // MARK: - Metadata

    func testMetadataComesFromTheDNGTags() throws {
        let merge = try open(LinearFixtures.mergeHDR).summary
        XCTAssertEqual(merge.cameraMake, "Nikon")
        XCTAssertEqual(merge.cameraModel, "D750")
        XCTAssertEqual(merge.blackLevel, 0)
        XCTAssertEqual(merge.whiteLevel, 1)
        XCTAssertEqual(merge.baselineExposure, 2)
        XCTAssertEqual(merge.orientation, 0)
        // cam_mul is LibRaw's inverse of AsShotNeutral, normalised to green.
        let m = merge.cameraMultipliers
        XCTAssertEqual(m.0, LinearFixtures.cameraMultipliers[0], accuracy: 1e-4)
        XCTAssertEqual(m.1, LinearFixtures.cameraMultipliers[1], accuracy: 1e-4)
        XCTAssertEqual(m.2, LinearFixtures.cameraMultipliers[2], accuracy: 1e-4)
        // The largest stored value: red 63/64 at the right edge.
        XCTAssertEqual(merge.dataMaximum, 63.0 / 64)
        XCTAssertEqual(merge.lens.minFocal, 35)
        XCTAssertEqual(merge.lens.maxApertureAtMinFocal, 1.8, accuracy: 1e-5)
        XCTAssertEqual(merge.focalLength, 35)

        let matrix = try XCTUnwrap(try open(LinearFixtures.mergeHDR).cameraToXYZMatrixRaw)
        for (got, want) in zip(matrix, LinearFixtures.cameraToXYZ) {
            XCTAssertEqual(got, want, accuracy: 1e-4)
        }

        XCTAssertEqual(try open(LinearFixtures.plain).summary.baselineExposure, -0.5)
        XCTAssertEqual(try open(LinearFixtures.ramp).summary.baselineExposure, 0)
        XCTAssertEqual(try open(LinearFixtures.orientation6).summary.orientation, 6)
    }

    func testMergeInfoIsReadFromTheXMPPacket() throws {
        XCTAssertEqual(try open(LinearFixtures.mergeHDR).summary.mergeInfo,
                       LinearMergeInfo(kind: "hdr", clipLevel: 0.5, lensApplied: false, baselineShift: 1))
        XCTAssertEqual(try open(LinearFixtures.mergePanorama).summary.mergeInfo,
                       LinearMergeInfo(kind: "panorama", clipLevel: 1, lensApplied: true, baselineShift: 0))
        XCTAssertNil(try open(LinearFixtures.plain).summary.mergeInfo)
    }

    /// The catalog opens files metadata-only; it still learns what they are.
    func testMetadataOnlyOpenKnowsTheSourceKindAndRecipe() throws {
        let file = try open(LinearFixtures.mergeHDR, metadataOnly: true)
        XCTAssertEqual(file.summary.sourceKind, .linearRGB)
        XCTAssertEqual(file.summary.mergeInfo?.clipLevel, 0.5)
        XCTAssertEqual(file.summary.whiteLevel, 1)
        XCTAssertEqual(file.summary.dataMaximum, 0, "not measured without the pixels")
        XCTAssertNil(file.linearPlane)
        XCTAssertNil(file.sensorPlane)
        XCTAssertNotNil(file.embeddedJPEGPreview(), "the merge's JPEG preview")
    }

    /// Clearing LibRaw's float-to-integer option leaves ordinary raws as
    /// they were: still Bayer, still integer, with the new fields sensible.
    /// (That their pixels are unchanged is what the golden tests pin.)
    func testBayerRawIsStillBayer() throws {
        let path = try TestAssets.d750Path()
        let file = try RawFile(path: path)
        let s = file.summary
        XCTAssertEqual(s.sourceKind, .bayer)
        guard case .bayer = s.cfaPattern else { return XCTFail("\(s.cfaPattern)") }
        XCTAssertNotNil(file.sensorPlane)
        XCTAssertNil(file.linearPlane)
        XCTAssertNil(s.mergeInfo)
        XCTAssertEqual(s.baselineExposure, 0)
        // The D750 has one black level for all four channels.
        XCTAssertEqual(s.channelBlackLevels, SIMD4(repeating: s.blackLevel))
        // Measured from the plane: never above what the plane holds.
        let plane = try XCTUnwrap(file.sensorPlane).samples
        XCTAssertEqual(s.dataMaximum, Float(plane.max()!))
        XCTAssertGreaterThan(s.dataMaximum, s.blackLevel)
    }

    // MARK: - The service's reply

    /// The app's half of an XPC decode: the metadata as JSON and the plane
    /// as a surface, adopted without copying.
    func testServiceReplyIsAdoptedAsALinearPlane() throws {
        let decoded = try open(LinearFixtures.mergeHDR)
        let json = try JSONEncoder().encode(decoded.snapshotMetadata)
        let meta = try JSONDecoder().decode(RawSnapshotMetadata.self, from: json)
        XCTAssertEqual(meta.planeSampleCount, 64 * 48 * 4)
        let surface = try XCTUnwrap(decoded.linearPlane?.surface)

        let adopted = try RawFile(serviceReply: meta, plane: surface, preview: nil, metadataOnly: false)
        XCTAssertTrue(adopted.decodedInService)
        XCTAssertEqual(adopted.summary.sourceKind, .linearRGB)
        XCTAssertEqual(adopted.summary.mergeInfo, decoded.summary.mergeInfo)
        XCTAssertEqual(adopted.summary.baselineExposure, 2)
        XCTAssertEqual(adopted.summary.channelBlackLevels, decoded.summary.channelBlackLevels)
        XCTAssertEqual(adopted.summary.dataMaximum, decoded.summary.dataMaximum)
        XCTAssertEqual(adopted.cameraToXYZMatrixRaw, decoded.cameraToXYZMatrixRaw)
        let plane = try XCTUnwrap(adopted.linearPlane)
        XCTAssertEqual(plane.pointer, decoded.linearPlane?.pointer, "the same memory, not a copy")
        XCTAssertNil(adopted.sensorPlane)
    }

    /// A reply claiming more pixels than its surface holds is refused, so a
    /// compromised decoder can't make the app read past the end.
    func testServiceReplyWithTooFewBytesIsRefused() throws {
        let decoded = try open(LinearFixtures.mergeHDR)
        let surface = try XCTUnwrap(decoded.linearPlane?.surface)
        var meta = decoded.snapshotMetadata
        let capacityPixels = surface.allocationSize / LinearPlane.bytesPerPixel
        meta.width = capacityPixels + 1
        meta.height = 1
        meta.planeSampleCount = meta.width * 4
        XCTAssertThrowsError(try RawFile(serviceReply: meta, plane: surface, preview: nil, metadataOnly: false))

        // A count that disagrees with the dimensions, likewise.
        var inconsistent = decoded.snapshotMetadata
        inconsistent.planeSampleCount = 64 * 48
        XCTAssertThrowsError(try RawFile(serviceReply: inconsistent, plane: surface, preview: nil,
                                         metadataOnly: false))

        XCTAssertNil(LinearPlane(surface: surface, width: capacityPixels + 1, height: 1))
        XCTAssertNil(LinearPlane(surface: surface, width: 0, height: 48))
        XCTAssertNil(LinearPlane(surface: surface, width: Int.max / 2, height: 4))
        XCTAssertNotNil(LinearPlane(surface: surface, width: capacityPixels, height: 1))
    }

    /// A merge recipe with a nonsensical clip level from a (compromised)
    /// service is refused when the app decodes the reply.
    func testReplyWithInvalidClipLevelIsRefused() throws {
        let decoded = try open(LinearFixtures.mergeHDR)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(decoded.snapshotMetadata), encoding: .utf8))
        let tampered = json.replacingOccurrences(of: "\"clipLevel\":0.5", with: "\"clipLevel\":-1")
        XCTAssertNotEqual(json, tampered)
        XCTAssertThrowsError(try JSONDecoder().decode(RawSnapshotMetadata.self, from: Data(tampered.utf8)))
    }

    // MARK: - Helpers

    private func assertPlane(_ plane: LinearPlane, skippingFirst skipped: Int = 0,
                             expected: (Int, Int) -> (Float16, Float16, Float16),
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let samples = plane.samples
        var mismatches = 0
        for y in 0..<plane.height {
            for x in 0..<plane.width where y > 0 || x >= skipped {
                let i = (y * plane.width + x) * 4
                let want = expected(x, y)
                if samples[i].bitPattern != want.0.bitPattern || samples[i + 1].bitPattern != want.1.bitPattern
                    || samples[i + 2].bitPattern != want.2.bitPattern || samples[i + 3] != 1 {
                    if mismatches < 5 {
                        XCTFail("(\(x), \(y)): got \(samples[i]) \(samples[i + 1]) \(samples[i + 2]) \(samples[i + 3]), "
                                + "want \(want)", file: file, line: line)
                    }
                    mismatches += 1
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "samples differing from what was written", file: file, line: line)
    }
}
