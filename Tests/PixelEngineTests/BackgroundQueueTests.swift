import XCTest
import Metal
import Synchronization
@testable import PixelEngine
@testable import RawCore

/// `GPUContext.background` (docs/Performance-Plan.md fix 24): the same
/// device, library and pipelines on a command queue of its own, so an
/// export's or thumbnail's command buffers don't queue in front of the
/// editor's. It must render exactly what the shared queue renders.
final class BackgroundQueueTests: XCTestCase {
    func testTwinSharesEverythingButTheQueue() throws {
        let gpu = try GPUContext()
        let background = gpu.background
        XCTAssertFalse(gpu.isBackground)
        XCTAssertTrue(background.isBackground)
        XCTAssertTrue(background === gpu.background, "made once")
        XCTAssertTrue(background.background === background)
        XCTAssertTrue(background.device === gpu.device)
        XCTAssertFalse(background.commandQueue === gpu.commandQueue)
        XCTAssertTrue(background.library === gpu.library)
        XCTAssertTrue(background.colorAndTonePSO === gpu.colorAndTonePSO)
        // The lazily built pipelines are one set: built through either, the same object.
        XCTAssertTrue(try background.lazyPipeline(.dfxEffectsApply) === gpu.lazyPipeline(.dfxEffectsApply))
    }

    func testBackgroundRenderMatchesTheSharedQueue() throws {
        let gpu = try GPUContext()
        let path = LinearFixtures.path(LinearFixtures.plain)
        var p = EditParameters()
        p.exposureEV = 0.5; p.clarity = 0.3; p.denoiseLuminance = 0.3; p.sharpenAmount = 0.5
        func render(_ context: GPUContext) throws -> [Float16] {
            let session = try ImageSession(file: try RawFile(path: path), gpu: context)
            let texture = try RenderPipeline(gpu: context).render(session, scale: .full, parameters: p)
            return try TextureReadback.float16Pixels(of: texture, gpu: context)
        }
        XCTAssertEqual(try render(gpu.background), try render(gpu))
    }

    /// Renders on both queues at once, each with its own session, as an
    /// export does while the editor renders: every result as rendered alone.
    func testConcurrentRendersOnBothQueues() throws {
        let gpu = try GPUContext()
        let path = try TestAssets.d750Path()   // big enough for the two queues' work to overlap
        var p = EditParameters()
        p.clarity = 0.3; p.sharpenAmount = 0.5
        let reference: [Float16] = try {
            let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
            return try TextureReadback.float16Pixels(of: try RenderPipeline(gpu: gpu).render(session, scale: .binned(quads: 2), parameters: p), gpu: gpu)
        }()
        let contexts = [gpu, gpu.background, gpu, gpu.background]
        let results = Mutex<[[Float16]]>([])
        DispatchQueue.concurrentPerform(iterations: contexts.count) { i in
            let context = contexts[i]
            guard let session = try? ImageSession(file: try RawFile(path: path), gpu: context) else { return }
            let pipeline = RenderPipeline(gpu: context)
            for _ in 0..<5 {
                guard let t = try? pipeline.render(session, scale: .binned(quads: 2), parameters: p),
                      let px = try? TextureReadback.float16Pixels(of: t, gpu: context) else { return }
                results.withLock { $0.append(px) }
            }
        }
        let all = results.withLock { $0 }
        XCTAssertEqual(all.count, contexts.count * 5)
        for px in all { XCTAssertEqual(px, reference) }
    }
}
