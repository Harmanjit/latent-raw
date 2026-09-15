import XCTest
import PixelEngine
@testable import MergeKit

/// Harman-sized stitches, timed and measured. They write about 800 MB of
/// scratch files and take minutes in a debug build, so they only run when
/// asked:
///
///     LATENT_PERF=1 swift test --filter PanoBlendPerformanceTests
///
/// LATENT_PANO_TILE sets the tile size (default 1,024 px).
final class PanoBlendPerformanceTests: XCTestCase {
    typealias Support = PanoBlendTestSupport

    /// Seventeen 24 MP photos decoded at span 2 (2008 x 3008 prepared), as
    /// Harman's panorama would be: one row of 17 (his own shoot, which comes
    /// out about 16,384 x 2,200), and two rows of 9 and 8, which fills
    /// 16,384 x 6,000 and puts five or six photos over many tiles.
    func testSeventeenFramesAtHarmansSize() throws {
        guard ProcessInfo.processInfo.environment["LATENT_PERF"] == "1" else {
            throw XCTSkip("set LATENT_PERF=1 to time a 17-photo stitch")
        }
        let gpu = try HDRTestSupport.gpu()
        let tile = ProcessInfo.processInfo.environment["LATENT_PANO_TILE"].flatMap(Int.init) ?? 1024
        // A D750's 24 MP portrait frame with a 50 mm lens, 35% overlap.
        let (width, height, focal) = (4016, 6016, 8379.0)
        let spacing = 0.65 * 2 * atan(Double(width) / 2 / focal)
        let rowOffset = 0.516 * 2 * atan(Double(height) / 2 / focal)
        let oneRow = (0..<17).map { Support.Shot(yaw: spacing * (Double($0) - 8), exposure: [1, 0.85, 1.2][$0 % 3]) }
        var twoRows: [Support.Shot] = []
        for i in 0..<9 { twoRows.append(Support.Shot(yaw: spacing * (Double(i) - 4), pitch: rowOffset / 2,
                                                     exposure: [1, 0.85, 1.2][i % 3])) }
        for i in 0..<8 { twoRows.append(Support.Shot(yaw: spacing * (Double(i) - 3.5), pitch: -rowOffset / 2,
                                                     exposure: [1.1, 0.9, 1][i % 3])) }

        for (name, shots) in [("one row of 17", oneRow), ("two rows, 9 + 8", twoRows)] {
            let cameras = Support.cameras(shots, width: width, height: height, focal: focal)
            var (layout, _) = Support.layout(cameras, projection: .cylindrical, pixelsPerRadian: focal, scale: 1)
            let scale = min(16_384 / Double(layout.canvas.width), 1)
            (layout, _) = Support.layout(cameras, projection: .cylindrical, pixelsPerRadian: focal, scale: scale)
            let output = PanoramaOutputSize(fullWidth: layout.canvas.width, fullHeight: layout.canvas.height,
                                            scale: scale, width: Int(Double(layout.canvas.width) * scale),
                                            height: Int(Double(layout.canvas.height) * scale), limit: .textureSide,
                                            decodeSpan: 2)
            let store = try PanoramaFrameStore(parent: Support.scratchParent())
            defer { store.removeScratch() }
            let clock = ContinuousClock()
            var start = clock.now
            try Support.render(cameras, shots: shots, sampleScale: 0.5, edge: 2 / (focal * scale), into: store)
            let rendered = Self.seconds(clock.now - start)

            let stitcher = try PanoramaStitcher(
                layout: layout, outputSize: output, frames: store,
                options: PanoramaBlendOptions(tileSize: tile, frameCacheBytes: 512 << 20), gpu: gpu)
            start = clock.now
            let plan = try stitcher.prepare()
            let prepared = Self.seconds(clock.now - start)
            start = clock.now
            var pixels = 0
            try stitcher.stitch { pixels += $0.region.pixelCount }
            let stitched = Self.seconds(clock.now - start)
            let statistics = stitcher.statistics
            XCTAssertEqual(pixels, output.width * output.height)
            print("""
                \(name): \(output.width) x \(output.height) from 17 x 2008 x 3008 (scale \(String(format: "%.3f", scale)))
                  \(plan.tileCount) tiles of \(plan.tileSize) px + \(plan.apron) apron, \(plan.bands) bands, \
                \(plan.tiledLevels) tiled levels, half overlap \(Int(plan.halfOverlap ?? 0)) px, \
                \(plan.mostCamerasPerTile) photos over the busiest tile
                  seams \(String(format: "%.1f", prepared)) s, tiles \(String(format: "%.1f", stitched)) s, \
                \(statistics.frameUploads) frame uploads, photos rendered in \(String(format: "%.0f", rendered)) s
                  peak textures \(statistics.peakTextureBytes >> 20) MB (estimate \
                \(plan.estimatedPeakTextureBytes(frameCacheBytes: 512 << 20, largestFrameBytes: 2008 * 3008 * 8) >> 20) \
                MB), peak process GPU \(statistics.peakDeviceBytes >> 20) MB
                """)
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
}
