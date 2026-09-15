import os
import PixelEngine
import XCTest
@testable import MergeKit

/// A write that fails never leaves a file under the real name, nor a
/// hidden temporary one; invalid input is refused before any byte is written.
final class DNGWriteSafetyTests: XCTestCase {
    struct Boom: Error {}

    nonisolated(unsafe) private var folder: URL!

    override func setUpWithError() throws { folder = try Fixtures.temporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func contents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    private var writer: LinearRawDNGWriter {
        var writer = LinearRawDNGWriter(tileSize: 64, previewLongEdge: 64, thumbnailLongEdge: 32)
        writer.availableCapacity = { _ in nil }
        return writer
    }

    private func write(_ source: LinearRawPixelSource, with writer: LinearRawDNGWriter? = nil, maximum: Float = 1,
                       metadata: MergeDNGMetadata? = nil, name: String = "merge.dng",
                       replacingExisting: Bool = false) throws -> MergeDNGWriteResult {
        try (writer ?? self.writer).write(source, maximum: maximum, metadata: metadata ?? Fixtures.metadata(),
                                          recipe: Fixtures.recipe(), preview: Fixtures.previewImage(width: 64, height: 48),
                                          to: folder.appendingPathComponent(name), replacingExisting: replacingExisting)
    }

    private func grey(_ width: Int = 200, _ height: Int = 150, value: Float16 = 0.5) throws -> LinearRawPixelSource {
        try .buffer([Float16](repeating: value, count: width * height * 3), width: width, height: height)
    }

    func testAThrowingSourceLeavesNoFile() throws {
        nonisolated(unsafe) var calls = 0
        let source = LinearRawPixelSource(width: 200, height: 150) { region, rgb in
            calls += 1
            if calls == 3 { throw Boom() }
            rgb.update(repeating: 0.25)
        }
        XCTAssertThrowsError(try write(source)) { XCTAssertTrue($0 is Boom, "\($0)") }
        XCTAssertEqual(calls, 3, "stopped at the failing tile")
        XCTAssertEqual(try contents(), [], "neither the DNG nor its temporary file")
    }

    func testASampleAboveTheStatedMaximumStopsTheWrite() throws {
        var pixels = [Float16](repeating: 0.5, count: 200 * 150 * 3)
        pixels[150 * 200 * 3 - 1] = 3          // bottom-right pixel's blue, in the last tile
        XCTAssertThrowsError(try write(.buffer(pixels, width: 200, height: 150), maximum: 2)) { error in
            guard case MergeDNGError.sampleOutOfRange(let region, let value) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(region, PixelRegion(x: 192, y: 128, width: 8, height: 22))
            XCTAssertEqual(value, 3)
        }
        XCTAssertEqual(try contents(), [])
    }

    func testNaNAndInfinityAreRefused() throws {
        for bad in [Float16.nan, .infinity, -.infinity] {
            var pixels = [Float16](repeating: 0.5, count: 20 * 20 * 3)
            pixels[7] = bad
            XCTAssertThrowsError(try write(.buffer(pixels, width: 20, height: 20))) { error in
                guard case MergeDNGError.sampleOutOfRange = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertThrowsError(try write(grey(), maximum: .nan))
        XCTAssertThrowsError(try write(grey(), maximum: 1e9), "more than half floats can hold")
        XCTAssertEqual(try contents(), [])
    }

    func testAnExistingFileIsNeverReplacedByDefault() throws {
        let url = folder.appendingPathComponent("merge.dng")
        try Data("someone else's photo".utf8).write(to: url)
        XCTAssertThrowsError(try write(grey())) { XCTAssertTrue($0 is SafeFileWriter.DestinationExists, "\($0)") }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "someone else's photo")
        XCTAssertEqual(try contents(), ["merge.dng"])

        let replaced = try write(grey(), replacingExisting: true)
        XCTAssertEqual(try TestTIFFReader(url: replaced.url).bytes.count, replaced.byteCount)
        XCTAssertEqual(try contents(), ["merge.dng"])
    }

    func testTooLittleFreeSpaceThrowsBeforeWriting() throws {
        var small = writer
        small.freeSpaceMargin = 1000
        small.availableCapacity = { _ in 50_000 }
        XCTAssertThrowsError(try write(grey(), with: small)) { error in
            guard case MergeDNGError.insufficientDiskSpace(let needed, let available) = error else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(available, 50_000)
            XCTAssertGreaterThan(needed, 200 * 150 * 6)
            XCTAssertTrue("\(error)".hasPrefix("Not enough disk space"))
        }
        XCTAssertEqual(try contents(), [])

        small.availableCapacity = { _ in 100_000_000 }
        XCTAssertNoThrow(try write(grey(), with: small))
    }

    func testTheRealVolumeReportsFreeSpace() {
        let capacity = LinearRawDNGWriter.volumeAvailableCapacity(at: folder.appendingPathComponent("x.dng"))
        XCTAssertGreaterThan(capacity ?? 0, 0)
    }

    func testCancellingTheTaskStopsBetweenTiles() async throws {
        let folder = self.folder!
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let task = Task.detached {
            let source = LinearRawPixelSource(width: 640, height: 640) { _, rgb in
                let call = calls.withLock { $0 += 1; return $0 }
                // As if the user pressed Cancel while the second tile was being made.
                if call == 2 { withUnsafeCurrentTask { $0?.cancel() } }
                rgb.update(repeating: 0.5)
            }
            var writer = LinearRawDNGWriter(tileSize: 64, previewLongEdge: 64, thumbnailLongEdge: 32)
            writer.availableCapacity = { _ in nil }
            return try writer.write(source, maximum: 1, metadata: Fixtures.metadata(), recipe: Fixtures.recipe(),
                                    preview: Fixtures.previewImage(width: 64, height: 48),
                                    to: folder.appendingPathComponent("cancelled.dng"))
        }
        do {
            _ = try await task.value
            XCTFail("the write finished despite the cancel")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(calls.withLock { $0 }, 2, "stopped before the third of 100 tiles")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    func testInvalidInputIsRefusedUpFront() throws {
        var odd = writer
        odd.tileSize = 100
        XCTAssertThrowsError(try write(grey(), with: odd)) { XCTAssertEqual($0 as? MergeDNGError, .invalidTileSize(100)) }

        XCTAssertThrowsError(try LinearRawPixelSource.buffer([0, 0], width: 1, height: 1))
        XCTAssertThrowsError(try LinearRawPixelSource.buffer([], width: 0, height: 5))

        var metadata = try Fixtures.metadata()
        metadata.software = "Adobe Photoshop Lightroom"
        XCTAssertThrowsError(try write(grey(), metadata: metadata)) { error in
            guard case MergeDNGError.invalidMetadata(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("Adobe"))
        }
        metadata = try Fixtures.metadata()
        metadata.software = "dcraw v9"
        XCTAssertThrowsError(try write(grey(), metadata: metadata))

        metadata = try Fixtures.metadata()
        metadata.colorMatrix1 = [1, 0, 0]
        XCTAssertThrowsError(try write(grey(), metadata: metadata))
        metadata = try Fixtures.metadata()
        metadata.asShotNeutral = [1, 0, 1]
        XCTAssertThrowsError(try write(grey(), metadata: metadata))
        metadata = try Fixtures.metadata()
        metadata.orientation = 9
        XCTAssertThrowsError(try write(grey(), metadata: metadata))
        metadata = try Fixtures.metadata()
        metadata.defaultCrop = PixelRegion(x: 100, y: 0, width: 101, height: 150)
        XCTAssertThrowsError(try write(grey(), metadata: metadata))
        metadata = try Fixtures.metadata()
        metadata.exposureTime = .infinity
        XCTAssertThrowsError(try write(grey(), metadata: metadata))
        XCTAssertEqual(try contents(), [])
    }
}
