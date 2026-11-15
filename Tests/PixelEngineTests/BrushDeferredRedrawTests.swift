import XCTest
import Metal
@testable import PixelEngine

/// Whole brush-mask redraws handed off the render (`BrushMaskSet.sync`
/// with `deferRedraws`): the bitmap that reaches the texture is the one
/// an on-the-spot redraw makes, byte for byte, and with edits arriving
/// faster than redraws finish only the latest strokes are ever uploaded.
final class BrushDeferredRedrawTests: XCTestCase {
    private let sensor = (width: 1600, height: 1200)

    /// Collects the jobs a set hands off, to run them when and in the
    /// order a test chooses.
    private final class Jobs: @unchecked Sendable {
        private let lock = NSLock()
        private var queued: [BrushRasterJob] = []
        func add(_ job: BrushRasterJob) { lock.lock(); queued.append(job); lock.unlock() }
        func take() -> [BrushRasterJob] { lock.lock(); defer { queued = []; lock.unlock() }; return queued }
        var scheduler: BrushRasterScheduler { { [self] job in add(job) } }
    }

    private func strokes(_ count: Int, feather: Float = 0.5, flow: Float = 1) -> [BrushStroke] {
        (0..<count).map { k in
            BrushStroke(points: (0..<30).map { j in SIMD2(0.15 + Float(j) * 0.02, 0.2 + Float(k) * 0.1) },
                        radius: 0.04, feather: feather, flow: flow, erase: k == 3)
        }
    }

    private func local(_ id: UUID, _ strokes: [BrushStroke]) -> LocalAdjustment {
        var l = LocalAdjustment(name: "brush", shape: .brush(strokes: strokes), exposureEV: 0.5)
        l.id = id
        return l
    }

    private func slice(_ set: BrushMaskSet, _ index: Int32) -> [UInt8] {
        let t = set.texture
        var out = [UInt8](repeating: 0, count: t.width * t.height)
        out.withUnsafeMutableBytes { bytes in
            t.getBytes(bytes.baseAddress!, bytesPerRow: t.width, bytesPerImage: t.width * t.height,
                       from: MTLRegionMake2D(0, 0, t.width, t.height), mipmapLevel: 0, slice: Int(index))
        }
        return out
    }

    /// What an on-the-spot sync uploads for `strokes`.
    private func expected(_ device: MTLDevice, _ strokes: [BrushStroke]) throws -> [UInt8] {
        let set = try XCTUnwrap(BrushMaskSet(device: device, sensorWidth: sensor.width, sensorHeight: sensor.height))
        let id = UUID()
        let slices = set.sync(locals: [local(id, strokes)], aiMasks: [:])
        return slice(set, try XCTUnwrap(slices[id]))
    }

    private func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "no Metal device")
    }

    func testJobDrawsExactlyWhatUpdateRedraws() throws {
        let all = strokes(6, feather: 0.3, flow: 0.7)
        let raster = try XCTUnwrap(BrushMaskRasterizer(sensorWidth: sensor.width, sensorHeight: sensor.height))
        _ = raster.update(strokes: strokes(2))   // something else first, then a full redraw
        XCTAssertEqual(raster.plan(strokes: all), .redraw)
        _ = raster.update(strokes: all)
        let job = BrushRasterJob(setID: UUID(), token: 1, elementID: UUID(), strokes: all, guide: nil,
                                 sensorWidth: sensor.width, sensorHeight: sensor.height)
        let result = try XCTUnwrap(job.run())
        XCTAssertEqual(result.raster.bytes, raster.pixels())

        // Adopting it then painting on matches painting on the original.
        let other = try XCTUnwrap(BrushMaskRasterizer(sensorWidth: sensor.width, sensorHeight: sensor.height))
        XCTAssertTrue(other.adopt(result.raster, strokes: all, guide: nil))
        XCTAssertEqual(other.plan(strokes: all), .upToDate)
        var more = all
        more[5].points.append(SIMD2(0.8, 0.7))
        XCTAssertEqual(other.plan(strokes: more), .appendPoints)
        _ = other.update(strokes: more)
        _ = raster.update(strokes: more)
        XCTAssertEqual(other.pixels(), raster.pixels())
    }

    /// Undo (a shorter list): the render keeps the old slice, the redraw
    /// lands, and the next sync uploads exactly the on-the-spot bitmap.
    func testDeferredRedrawUploadsTheExactMaskAfterwards() throws {
        let device = try device()
        let set = try XCTUnwrap(BrushMaskSet(device: device, sensorWidth: sensor.width, sensorHeight: sensor.height))
        let jobs = Jobs()
        let id = UUID()
        let five = strokes(5), four = Array(five.prefix(4))

        // A new slice is drawn on the spot even when deferring.
        let slices = set.sync(locals: [local(id, five)], aiMasks: [:], deferRedraws: jobs.scheduler)
        let index = try XCTUnwrap(slices[id])
        XCTAssertTrue(jobs.take().isEmpty)
        XCTAssertEqual(slice(set, index), try expected(device, five))

        _ = set.sync(locals: [local(id, four)], aiMasks: [:], deferRedraws: jobs.scheduler)
        let queued = jobs.take()
        XCTAssertEqual(queued.count, 1)
        XCTAssertEqual(slice(set, index), try expected(device, five), "unchanged until the redraw lands")
        XCTAssertTrue(set.hasPendingRedraws)

        // The same strokes again while it runs: no second job.
        _ = set.sync(locals: [local(id, four)], aiMasks: [:], deferRedraws: jobs.scheduler)
        XCTAssertTrue(jobs.take().isEmpty)

        XCTAssertTrue(set.apply(try XCTUnwrap(queued[0].run())))
        XCTAssertFalse(set.apply(try XCTUnwrap(queued[0].run())), "a second delivery is stale")
        _ = set.sync(locals: [local(id, four)], aiMasks: [:], deferRedraws: jobs.scheduler)
        XCTAssertTrue(jobs.take().isEmpty)
        XCTAssertFalse(set.hasPendingRedraws)
        XCTAssertEqual(slice(set, index), try expected(device, four))
    }

    /// Feather moved three times while the first redraw ran: its result is
    /// never uploaded, one more redraw runs for the latest, and that is
    /// what the texture ends with.
    func testFastChangesUploadOnlyTheLatest() throws {
        let device = try device()
        let set = try XCTUnwrap(BrushMaskSet(device: device, sensorWidth: sensor.width, sensorHeight: sensor.height))
        let jobs = Jobs()
        let id = UUID()
        let index = try XCTUnwrap(set.sync(locals: [local(id, strokes(5))], aiMasks: [:],
                                           deferRedraws: jobs.scheduler)[id])
        let original = slice(set, index)

        _ = set.sync(locals: [local(id, strokes(5, feather: 0.6))], aiMasks: [:], deferRedraws: jobs.scheduler)
        let first = jobs.take()
        _ = set.sync(locals: [local(id, strokes(5, feather: 0.7))], aiMasks: [:], deferRedraws: jobs.scheduler)
        _ = set.sync(locals: [local(id, strokes(5, feather: 0.8))], aiMasks: [:], deferRedraws: jobs.scheduler)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(jobs.take().isEmpty, "one redraw at a time")

        // The first lands: stale, so no render is asked for and the next
        // redraw (for 0.8) starts.
        XCTAssertFalse(set.apply(try XCTUnwrap(first[0].run())))
        let second = jobs.take()
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].strokes, strokes(5, feather: 0.8))
        _ = set.sync(locals: [local(id, strokes(5, feather: 0.8))], aiMasks: [:], deferRedraws: jobs.scheduler)
        XCTAssertEqual(slice(set, index), original, "nothing stale was uploaded")

        XCTAssertTrue(set.apply(try XCTUnwrap(second[0].run())))
        _ = set.sync(locals: [local(id, strokes(5, feather: 0.8))], aiMasks: [:], deferRedraws: jobs.scheduler)
        XCTAssertEqual(slice(set, index), try expected(device, strokes(5, feather: 0.8)))
    }

    /// A render that may not defer (export, the magnifier, masked scopes)
    /// brings the slice up to date itself. The redraw still running is not
    /// adopted, but its landing still asks for a render, since the
    /// editor's preview shows the old pixels until one runs. A deferring
    /// sync that finds the slice current, as after undo then redo back to
    /// what is drawn, drops it outright.
    func testOnTheSpotSyncOvertakesARunningRedraw() throws {
        let device = try device()
        let set = try XCTUnwrap(BrushMaskSet(device: device, sensorWidth: sensor.width, sensorHeight: sensor.height))
        let jobs = Jobs()
        let id = UUID()
        let five = strokes(5), four = Array(five.prefix(4)), three = Array(five.prefix(3))
        let index = try XCTUnwrap(set.sync(locals: [local(id, five)], aiMasks: [:], deferRedraws: jobs.scheduler)[id])

        _ = set.sync(locals: [local(id, four)], aiMasks: [:], deferRedraws: jobs.scheduler)
        let running = jobs.take()
        _ = set.sync(locals: [local(id, three)], aiMasks: [:])
        XCTAssertEqual(slice(set, index), try expected(device, three))
        XCTAssertTrue(set.hasPendingRedraws, "the preview still shows the old mask")
        XCTAssertTrue(set.apply(try XCTUnwrap(running[0].run())), "asks for the render that shows it")
        XCTAssertFalse(set.hasPendingRedraws)
        XCTAssertEqual(slice(set, index), try expected(device, three), "the old result is not adopted")
        XCTAssertTrue(jobs.take().isEmpty)
        _ = set.sync(locals: [local(id, three)], aiMasks: [:], deferRedraws: jobs.scheduler)
        XCTAssertEqual(slice(set, index), try expected(device, three))

        _ = set.sync(locals: [local(id, five)], aiMasks: [:], deferRedraws: jobs.scheduler)   // redo: a redraw
        let redo = jobs.take()
        XCTAssertEqual(redo.count, 1)
        _ = set.sync(locals: [local(id, three)], aiMasks: [:], deferRedraws: jobs.scheduler)  // undo again: current
        XCTAssertFalse(set.hasPendingRedraws)
        XCTAssertFalse(set.apply(try XCTUnwrap(redo[0].run())))
        XCTAssertEqual(slice(set, index), try expected(device, three))
    }

    /// A render that does not defer brings the slice current while a
    /// redraw runs, then the strokes change again: a fresh redraw starts
    /// at once (the running one's bitmap is older than the slice), and
    /// only its result is adopted.
    func testRedrawAfterAnOnTheSpotSyncStartsAfresh() throws {
        let device = try device()
        let set = try XCTUnwrap(BrushMaskSet(device: device, sensorWidth: sensor.width, sensorHeight: sensor.height))
        let jobs = Jobs()
        let id = UUID()
        let five = strokes(5), four = Array(five.prefix(4)), three = Array(five.prefix(3))
        let index = try XCTUnwrap(set.sync(locals: [local(id, five)], aiMasks: [:], deferRedraws: jobs.scheduler)[id])

        _ = set.sync(locals: [local(id, four)], aiMasks: [:], deferRedraws: jobs.scheduler)
        let first = jobs.take()
        _ = set.sync(locals: [local(id, four)], aiMasks: [:])   // the magnifier, say
        _ = set.sync(locals: [local(id, three)], aiMasks: [:], deferRedraws: jobs.scheduler)
        let second = jobs.take()
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].strokes, three)
        XCTAssertEqual(slice(set, index), try expected(device, four))
        XCTAssertFalse(set.apply(try XCTUnwrap(first[0].run())), "superseded")
        XCTAssertTrue(set.apply(try XCTUnwrap(second[0].run())))
        _ = set.sync(locals: [local(id, three)], aiMasks: [:], deferRedraws: jobs.scheduler)
        XCTAssertFalse(set.hasPendingRedraws)
        XCTAssertEqual(slice(set, index), try expected(device, three))
    }

    /// Painting on while a redraw runs: when it lands, the new dabs are
    /// appended on the spot and the exact mask is uploaded.
    func testPaintingWhileARedrawRunsCatchesUpByAppending() throws {
        let device = try device()
        let set = try XCTUnwrap(BrushMaskSet(device: device, sensorWidth: sensor.width, sensorHeight: sensor.height))
        let jobs = Jobs()
        let id = UUID()
        let five = strokes(5)
        let index = try XCTUnwrap(set.sync(locals: [local(id, five)], aiMasks: [:], deferRedraws: jobs.scheduler)[id])

        var painted = Array(five.prefix(3))
        _ = set.sync(locals: [local(id, painted)], aiMasks: [:], deferRedraws: jobs.scheduler)
        let running = jobs.take()
        painted.append(BrushStroke(points: [SIMD2(0.5, 0.5)], radius: 0.05, feather: 0.5, flow: 1, erase: false))
        _ = set.sync(locals: [local(id, painted)], aiMasks: [:], deferRedraws: jobs.scheduler)
        painted[3].points.append(SIMD2(0.55, 0.52))
        _ = set.sync(locals: [local(id, painted)], aiMasks: [:], deferRedraws: jobs.scheduler)
        XCTAssertTrue(jobs.take().isEmpty)

        XCTAssertTrue(set.apply(try XCTUnwrap(running[0].run())), "appending catches up")
        XCTAssertTrue(jobs.take().isEmpty)
        _ = set.sync(locals: [local(id, painted)], aiMasks: [:], deferRedraws: jobs.scheduler)
        XCTAssertFalse(set.hasPendingRedraws)
        XCTAssertEqual(slice(set, index), try expected(device, painted))
    }
}
