import XCTest
import Metal
import PixelEngine
@testable import MergeKit

/// The stitcher's lifecycle: cancelling, cleaning up scratch files, memory,
/// and streaming to the DNG writer's pixel source.
final class PanoBlendLifecycleTests: XCTestCase {
    typealias Support = PanoBlendTestSupport

    /// Cancelling between tiles throws `CancellationError` and deletes the
    /// frames' scratch files; so does cancelling during the coarse pass.
    func testCancellationRemovesTheScratchFiles() throws {
        let gpu = try HDRTestSupport.gpu()
        let row = Support.row()
        for cancelAfterSeams in [false, true] {
            let store = try Support.store(for: row)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.path))
            let stitcher = try PanoramaStitcher(layout: row.layout, outputSize: row.output, frames: store,
                                                options: PanoramaBlendOptions(tileSize: 256), gpu: gpu)
            var tiles = 0, seamSteps = 0
            XCTAssertThrowsError(try stitcher.stitch(progress: { progress in
                if progress.stage == .seams { seamSteps = progress.completed }
            }, shouldCancel: {
                cancelAfterSeams ? seamSteps >= 2 : tiles >= 2
            }, consume: { _ in tiles += 1 })) { error in
                XCTAssertTrue(error is CancellationError, "\(error)")
            }
            XCTAssertEqual(tiles, cancelAfterSeams ? 0 : 2)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path), "scratch removed")
            XCTAssertNil(store.preparedFrame(0))
            XCTAssertThrowsError(try stitcher.stitch { _ in }, "a finished stitcher can't stitch again")
        }
    }

    /// A finished stitch removes the scratch files too, unless told not to.
    func testCompletionRemovesTheScratchFilesUnlessAsked() throws {
        let gpu = try HDRTestSupport.gpu()
        let row = Support.row(scale: 0.2)
        let store = try Support.store(for: row)
        _ = try Support.stitch(row.layout, row.output, frames: store,
                               options: PanoramaBlendOptions(removeScratchWhenFinished: false), gpu: gpu)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.path))
        _ = try Support.stitch(row.layout, row.output, frames: store, options: PanoramaBlendOptions(), gpu: gpu)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
    }

    /// With room for just one frame on the GPU, frames come and go, the
    /// cache never holds more than one, everything the stitch holds stays
    /// within the plan's estimate, and the panorama is exactly the same.
    func testMemoryStaysWithinTheBudget() throws {
        let gpu = try HDRTestSupport.gpu()
        let row = Support.row(scale: 1)
        let store = try Support.store(for: row)
        let roomy = try Support.stitch(row.layout, row.output, frames: store,
                                       options: PanoramaBlendOptions(tileSize: 512, removeScratchWhenFinished: false),
                                       gpu: gpu)
        let tight = try Support.stitch(row.layout, row.output, frames: store,
                                       options: PanoramaBlendOptions(tileSize: 512, frameCacheBytes: 1), gpu: gpu)
        let frameBytes = try XCTUnwrap(row.cameras.map { _ in 400 * 300 * 8 }.max())
        XCTAssertEqual(roomy.rgba, tight.rgba)
        // One frame with its mips, never two (allocations round up to pages).
        XCTAssertLessThan(tight.statistics.peakFrameCacheBytes, 2 * frameBytes)
        XCTAssertGreaterThan(tight.statistics.frameUploads, roomy.statistics.frameUploads)
        let estimate = tight.plan.estimatedPeakTextureBytes(frameCacheBytes: 0, largestFrameBytes: frameBytes)
        print("tight: peak textures \(tight.statistics.peakTextureBytes / 1000) kB (estimate \(estimate / 1000) kB), "
              + "uploads \(tight.statistics.frameUploads) vs \(roomy.statistics.frameUploads)")
        XCTAssertLessThanOrEqual(tight.statistics.peakTextureBytes, estimate)
    }

    /// The pull-style pixel source, read the way `LinearRawDNGWriter` reads
    /// (512 px regions in reading order), gives the stitch's RGB exactly,
    /// and deletes the scratch files after the last region.
    func testPixelSourceStreamsTheSameImage() throws {
        let gpu = try HDRTestSupport.gpu()
        let row = Support.row(scale: 1)
        let store = try Support.store(for: row)
        let pushed = try Support.stitch(row.layout, row.output, frames: store,
                                        options: PanoramaBlendOptions(tileSize: 1024, removeScratchWhenFinished: false),
                                        gpu: gpu)
        let stitcher = try PanoramaStitcher(layout: row.layout, outputSize: row.output, frames: store,
                                            options: PanoramaBlendOptions(tileSize: 1024), gpu: gpu)
        let source = try stitcher.pixelSource()
        XCTAssertEqual(source.width, row.output.width)
        XCTAssertEqual(source.height, row.output.height)
        var mismatches = 0
        var buffer = [Float16](repeating: 0, count: 512 * 512 * 3)
        for y in stride(from: 0, to: source.height, by: 512) {
            for x in stride(from: 0, to: source.width, by: 512) {
                XCTAssertTrue(FileManager.default.fileExists(atPath: store.directory.path))
                let region = PixelRegion(x: x, y: y, width: min(512, source.width - x), height: min(512, source.height - y))
                try buffer.withUnsafeMutableBufferPointer { try source.fill(region, $0) }
                for r in 0..<region.height {
                    for c in 0..<region.width {
                        let pixel = pushed.pixel(region.x + c, region.y + r)
                        for channel in 0..<3 where Float(buffer[(r * region.width + c) * 3 + channel]) != pixel[channel] {
                            mismatches += 1
                        }
                    }
                }
            }
        }
        XCTAssertEqual(mismatches, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path), "scratch removed after the last region")
    }

    /// The whole way out: the pixel source handed to `LinearRawDNGWriter`,
    /// written to a DNG and read back through RawCore, pixel for pixel.
    /// The writer asks for its own 512 px tiles as it goes, so the stitch
    /// never exists as a whole image anywhere.
    func testStreamsIntoTheDNGWriter() throws {
        let gpu = try HDRTestSupport.gpu()
        let row = Support.row(scale: 0.5)
        let store = try Support.store(for: row)
        let pushed = try Support.stitch(row.layout, row.output, frames: store,
                                        options: PanoramaBlendOptions(tileSize: 1024, removeScratchWhenFinished: false),
                                        gpu: gpu)
        let stitcher = try PanoramaStitcher(layout: row.layout, outputSize: row.output, frames: store,
                                            options: PanoramaBlendOptions(tileSize: 1024), gpu: gpu)
        let folder = try Fixtures.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("panorama-Pano.dng")
        let writer = LinearRawDNGWriter(tileSize: 512, previewLongEdge: 64, thumbnailLongEdge: 32)
        // The tiles stream past once, so the merge can't measure its own
        // maximum: it passes an upper bound (the clip level times the
        // largest gain), which only costs a little headroom.
        let result = try writer.write(stitcher.pixelSource(), maximum: 4, metadata: try Fixtures.metadata(),
                                      recipe: Fixtures.recipe(), preview: Fixtures.previewImage(), to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path), "scratch removed after the write")
        let read = try HDRTestSupport.readBack(result.url)
        XCTAssertEqual(read.width, row.output.width)
        XCTAssertEqual(read.height, row.output.height)
        var largest: Float = 0
        for y in 0..<read.height {
            for x in 0..<read.width {
                let stored = read.pixel(x, y), expected = pushed.pixel(x, y)
                for c in 0..<3 { largest = max(largest, abs(stored[c] - expected[c])) }
            }
        }
        // Half floats divided by 4 and multiplied back: exact.
        XCTAssertEqual(largest, 0)
    }

    // MARK: - The frame store

    func testFrameStoreKeepsFramesInScratchFiles() throws {
        let gpu = try HDRTestSupport.gpu()
        let store = try PanoramaFrameStore(parent: Support.scratchParent())
        try store.add(frameIndex: 3, width: 5, height: 4, sampleScale: 0.5) { pixels in
            for i in 0..<pixels.count { pixels[i] = Float16(i) }
        }
        // From a private texture, as frame preparation would hand it over.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 7, height: 700,
                                                                  mipmapped: false)
        descriptor.usage = [.shaderRead]
        let shared = try XCTUnwrap(gpu.device.makeTexture(descriptor: descriptor))
        let values = (0..<(7 * 700 * 4)).map { Float16($0 % 1000) }
        values.withUnsafeBytes { shared.replace(region: MTLRegionMake2D(0, 0, 7, 700), mipmapLevel: 0,
                                                withBytes: $0.baseAddress!, bytesPerRow: 7 * 8) }
        descriptor.storageMode = .private
        let privateTexture = try XCTUnwrap(gpu.device.makeTexture(descriptor: descriptor))
        let commands = try XCTUnwrap(gpu.commandQueue.makeCommandBuffer())
        let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
        blit.copy(from: shared, to: privateTexture)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        try store.add(frameIndex: 8, texture: privateTexture, sampleScale: 1, commandQueue: gpu.commandQueue,
                      bandHeight: 256)

        XCTAssertEqual(store.preparedFrame(3), PanoramaPreparedFrame(frameIndex: 3, width: 5, height: 4, sampleScale: 0.5))
        XCTAssertEqual(store.byteCount, 5 * 4 * 8 + 7 * 700 * 8)
        try store.withPixels(of: 3) { bytes in
            let halves = bytes.bindMemory(to: Float16.self)
            XCTAssertEqual(halves[79], 79)
        }
        try store.withPixels(of: 8) { bytes in
            XCTAssertEqual(Array(bytes.bindMemory(to: Float16.self)), values)
        }
        XCTAssertThrowsError(try store.withPixels(of: 4) { _ in })
        XCTAssertThrowsError(try store.add(frameIndex: 1, width: 0, height: 4, sampleScale: 1) { _ in })
        store.removeScratch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertNil(store.preparedFrame(3))
    }

    /// Launch-time cleanup removes folders of processes that are gone and
    /// keeps live ones; quit-time cleanup removes this process's.
    func testAbandonedScratchIsRemoved() throws {
        let parent = Support.scratchParent().appendingPathComponent("abandoned-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let live = try PanoramaFrameStore(parent: parent)
        // PIDs are below 100,000 on macOS; this one can't be running.
        let dead = parent.appendingPathComponent("99999999-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dead, withIntermediateDirectories: true)
        XCTAssertEqual(PanoramaFrameStore.removeAbandonedScratch(parent: parent), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dead.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.directory.path))
        XCTAssertEqual(PanoramaFrameStore.removeScratchOfThisProcess(parent: parent), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: live.directory.path))
    }

    /// macOS hands process ids out again within a day or two, so a crashed
    /// panorama's 3 GB folder must not be kept for ever just because some
    /// other process now holds the id it was named after. A folder nothing
    /// has touched for a day goes whatever its id says — except this
    /// process's own, which are named after it and are live by definition.
    func testAScratchFolderWhosePIDWasHandedOnGoesByItsAge() throws {
        let parent = Support.scratchParent().appendingPathComponent("recycled-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        // Named after pid 1 (launchd): always running, never this process,
        // and `kill(1, 0)` answers EPERM, so the folder looks live.
        let recycled = parent.appendingPathComponent("1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: recycled, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-PanoramaFrameStore.abandonedAfter - 60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: recycled.path)

        // A live store of this process is never touched, however it looks.
        let live = try PanoramaFrameStore(parent: parent)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: live.directory.path)

        XCTAssertEqual(PanoramaFrameStore.removeAbandonedScratch(parent: parent), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recycled.path), "a day old and not ours: abandoned")
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.directory.path), "ours, so never by age")
        live.removeScratch()
    }

    /// A folder whose id is in use and which was written a moment ago is a
    /// stitch that is still running: left alone.
    func testARecentScratchFolderOfALiveProcessIsKept() throws {
        let parent = Support.scratchParent().appendingPathComponent("recent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let fresh = parent.appendingPathComponent("1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        XCTAssertEqual(PanoramaFrameStore.removeAbandonedScratch(parent: parent,
                                                                 now: Date().addingTimeInterval(60)), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testMissingFrameIsReported() throws {
        let gpu = try HDRTestSupport.gpu()
        let row = Support.row()
        let store = try PanoramaFrameStore(parent: Support.scratchParent())
        defer { store.removeScratch() }
        XCTAssertThrowsError(try PanoramaStitcher(layout: row.layout, outputSize: row.output, frames: store, gpu: gpu)) {
            XCTAssertEqual($0 as? PanoramaBlendError, .missingFrame(frameIndex: 0))
        }
    }
}
