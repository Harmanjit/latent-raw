import XCTest
import RawCore
@testable import MergeKit

/// The shape of the main image's tile grid, which LibRaw is picky about.
///
/// A grid of exactly four tiles used to come back wrong: LibRaw 0.22.2
/// reads a TileOffsets count of 4 as the mark of a Sinar 4-shot camera file
/// and swaps in `sinar_4shot_load_raw`, which reads plain 16-bit integers.
/// A 900 x 600 merge came back as the bit patterns of its half floats, and
/// 1024 x 1024 didn't open at all. `LinearRawDNGWriter.tileSize` keeps the
/// grid off that count; these tests hold it to that over a range of sizes a
/// downsampled panorama could land on.
final class DNGTileGridTests: XCTestCase {
    /// Writes an image of this size and reads it back through `RawFile`,
    /// as the app opens any photo. Returns how many samples came back wrong.
    private func roundTripMismatches(width: Int, height: Int) throws -> Int {
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pixels = Fixtures.pixels(width: width, height: height, maximum: 1)
        var writer = LinearRawDNGWriter()
        writer.availableCapacity = { _ in nil }
        let result = try writer.write(.buffer(pixels, width: width, height: height), maximum: 1,
                                      metadata: Fixtures.metadata(baselineExposure: 0), recipe: Fixtures.recipe(),
                                      preview: Fixtures.previewImage(),
                                      to: folder.appendingPathComponent("grid.dng"))
        let file = try RawFile(path: result.url.path)
        let plane = try XCTUnwrap(file.linearPlane, "\(width) x \(height) opened without a linear plane")
        XCTAssertEqual([plane.width, plane.height], [width, height], "\(width) x \(height)")
        guard plane.width == width, plane.height == height else { return width * height * 3 }
        let rgba = plane.samples
        var mismatches = 0
        for i in 0..<(width * height) {
            for c in 0..<3 where rgba[i * 4 + c].bitPattern != pixels[i * 3 + c].bitPattern { mismatches += 1 }
        }
        return mismatches
    }

    /// The sizes the round trip is checked at: each dimension swept from 200
    /// to 2400 px on its own, so both are covered end to end without writing
    /// a file for every pair. The other side cycles through shapes that put
    /// the sweep on both sides of every tile boundary.
    private static var sweptSizes: [(Int, Int)] {
        let others = [200, 300, 512, 513, 600, 700, 1024]
        var sizes: [(Int, Int)] = []
        for (step, side) in stride(from: 200, through: 2400, by: 200).enumerated() {
            sizes.append((side, others[step % others.count]))
            sizes.append((others[(step + 3) % others.count], side))
        }
        // The sizes that used to fail, and one big square.
        sizes += [(900, 600), (1024, 1024), (1600, 512), (512, 1600), (700, 700), (2400, 2400)]
        return sizes
    }

    /// No image gets a four-tile grid, at any size from 200 to 2400 px.
    /// Pure arithmetic, so it can sweep every size rather than a sample.
    func testNoSizeGetsFourTiles() {
        var worst: (width: Int, height: Int, tile: Int)?
        for width in 200...2400 {
            for height in 200...2400 {
                let tile = LinearRawDNGWriter.tileSize(512, width: width, height: height)
                if LinearRawDNGWriter.tileCount(tile, width: width, height: height) == 4 || tile % 16 != 0
                    || tile < 16 || tile > min(width, height) {
                    worst = (width, height, tile)
                    break
                }
            }
            if worst != nil { break }
        }
        XCTAssertNil(worst, "\(worst?.width ?? 0) x \(worst?.height ?? 0) got a \(worst?.tile ?? 0) px tile")
    }

    /// Every swept size writes a DNG LibRaw gives back sample for sample.
    func testSweptSizesReadBackBitExact() throws {
        for (width, height) in Self.sweptSizes {
            let tile = LinearRawDNGWriter.tileSize(512, width: width, height: height)
            XCTAssertNotEqual(LinearRawDNGWriter.tileCount(tile, width: width, height: height), 4,
                              "\(width) x \(height) was tiled four ways")
            XCTAssertEqual(try roundTripMismatches(width: width, height: height), 0,
                           "samples that didn't come back from \(width) x \(height) (\(tile) px tiles)")
        }
    }

    /// What the four-tile grids became, so the fix is visible rather than
    /// only implied: each of these used to be tiled four ways at 512 px.
    func testFormerlyFourTileSizesAreTiledSmaller() {
        for (width, height, tile, count) in [(900, 600, 256, 12), (1024, 1024, 256, 16),
                                             (1600, 512, 256, 14), (700, 700, 256, 9),
                                             (517, 389, 192, 9)] {
            XCTAssertEqual(LinearRawDNGWriter.tileSize(512, width: width, height: height), tile,
                           "\(width) x \(height)")
            XCTAssertEqual(LinearRawDNGWriter.tileCount(tile, width: width, height: height), count,
                           "\(width) x \(height)")
        }
    }
}
