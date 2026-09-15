import XCTest
@testable import MergeKit

/// A full-size write, timed. Allocates and writes about 300 MB, so it only
/// runs when asked: LATENT_PERF=1 swift test --filter DNGWritePerformanceTests
final class DNGWritePerformanceTests: XCTestCase {
    func test45MegapixelWrite() throws {
        guard ProcessInfo.processInfo.environment["LATENT_PERF"] == "1" else {
            throw XCTSkip("set LATENT_PERF=1 to time a 45 MP write")
        }
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (width, height) = (8256, 5504)   // Nikon D850
        // A generated source rather than a buffer: the point is that the
        // writer itself never holds the image.
        let source = LinearRawPixelSource(width: width, height: height) { region, rgb in
            guard let base = rgb.baseAddress else { return }
            for y in 0..<region.height {
                // One grey per row, laid down with memset_pattern4 (a quick
                // libc fill even in a debug build) as two copies of the half float.
                let v = Float16(Float(region.y + y) / Float(height) * 7).bitPattern
                withUnsafeBytes(of: (v, v)) { pattern in
                    memset_pattern4(base + y * region.width * 3, pattern.baseAddress, region.width * 3 * 2)
                }
            }
        }
        let writer = LinearRawDNGWriter()
        let start = Date()
        let result = try writer.write(source, maximum: 7, metadata: Fixtures.metadata(), recipe: Fixtures.recipe(),
                                      preview: Fixtures.previewImage(width: 1600, height: 1067),
                                      to: folder.appendingPathComponent("45mp.dng"))
        let seconds = Date().timeIntervalSince(start)
        print(String(format: "45 MP DNG: %.0f MB in %.2f s", Double(result.byteCount) / 1e6, seconds))
        XCTAssertGreaterThan(result.byteCount, width * height * 6)
        // About 0.2 s on an M1 Pro, debug build included (the per-sample work
        // is Accelerate's); generous for slower disks.
        XCTAssertLessThan(seconds, 3)
    }
}
