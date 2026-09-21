import XCTest
import Metal
import Darwin
@testable import PixelEngine
@testable import RawCore

/// What a session gives back when macOS runs short of memory, and the
/// RAM-size policy. The release tests render a real D750 raw and skip
/// without one (see TestAssets/README.md).
final class MemoryPressureTests: XCTestCase {
    func testPolicyTreatsEightGigabytesAsConstrained() {
        XCTAssertTrue(MemoryPolicy(physicalMemory: 8 << 30).isConstrained)
        XCTAssertFalse(MemoryPolicy(physicalMemory: 8 << 30).keepsIdleImages)
        XCTAssertFalse(MemoryPolicy(physicalMemory: 16 << 30).isConstrained)
        XCTAssertTrue(MemoryPolicy(physicalMemory: 16 << 30).keepsIdleImages)
    }

    func testLevelTakesTheMostSevereEvent() {
        XCTAssertEqual(MemoryPressureLevel(.warning), .warning)
        XCTAssertEqual(MemoryPressureLevel(.critical), .critical)
        XCTAssertEqual(MemoryPressureLevel([.warning, .critical]), .critical)
        XCTAssertEqual(MemoryPressureLevel(.normal), .normal)
        XCTAssertNil(MemoryPressureLevel([]))
        XCTAssertLessThan(MemoryPressureLevel.warning, .critical)
    }

    private func openSession() throws -> (ImageSession, RenderPipeline, GPUContext) {
        let path = try TestAssets.d750Path()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: path), gpu: gpu)
        return (session, RenderPipeline(gpu: gpu), gpu)
    }

    /// Renders a preview and a 100% tile the way the viewport does, so the
    /// pool holds intermediates, not just the textures handed back.
    private func renderLikeTheViewport(_ session: ImageSession, _ pipeline: RenderPipeline) throws -> MTLTexture {
        _ = try pipeline.render(session, scale: .binned(quads: 2), parameters: .neutral)
        return try pipeline.render(session, scale: .region(x: 1000, y: 1000, width: 1600, height: 1000),
                                   parameters: .neutral)
    }

    private func smallTexture(_ gpu: GPUContext) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 64, height: 64,
                                                         mipmapped: false)
        d.storageMode = .shared
        return gpu.device.makeTexture(descriptor: d)
    }

    func testWarningReleasesPooledTexturesAndKeepsTheDenoiseResult() throws {
        let (session, pipeline, gpu) = try openSession()
        weak var pooledIntermediate: MTLTexture?
        let shown: MTLTexture = try autoreleasepool {
            let shown = try renderLikeTheViewport(session, pipeline)
            // Any pooled texture that isn't the one on screen.
            pooledIntermediate = try session.texture(width: 1600, height: 1000, pixelFormat: .rgba16Float,
                                                     role: .cameraRGB)
            return shown
        }
        session.setAIDenoised(smallTexture(gpu), model: "test")
        let before = session.approximateBytesHeld
        XCTAssertNotNil(pooledIntermediate)

        let droppedDenoise = session.releaseMemory(for: .warning)

        XCTAssertFalse(droppedDenoise)
        XCTAssertNil(pooledIntermediate, "nothing else holds pooled intermediates, so they are freed")
        XCTAssertEqual(shown.width, 1600, "a texture the caller holds is untouched")
        XCTAssertNotNil(session.aiDenoisedCameraRGB, "11 s to recompute: only critical may drop it")
        let after = session.approximateBytesHeld
        XCTAssertLessThan(after, before)
        XCTAssertEqual(after, session.sensorBuffer.length + (session.aiDenoisedCameraRGB?.allocatedSize ?? 0))

        // Still a working session: the next render rebuilds what it needs.
        let again = try renderLikeTheViewport(session, pipeline)
        XCTAssertEqual(again.width, 1600)
        XCTAssertFalse(again === shown, "a fresh texture, not one that was released")
    }

    func testCriticalAlsoDropsTheDenoiseResult() throws {
        let (session, pipeline, gpu) = try openSession()
        _ = try renderLikeTheViewport(session, pipeline)
        weak var denoised: MTLTexture?
        autoreleasepool {
            let texture = smallTexture(gpu)
            denoised = texture
            session.setAIDenoised(texture, model: "test")
        }

        XCTAssertTrue(session.releaseMemory(for: .critical))
        XCTAssertNil(session.aiDenoisedCameraRGB)
        XCTAssertNil(session.aiDenoiseModel)
        XCTAssertNil(denoised)
        XCTAssertEqual(session.approximateBytesHeld, session.sensorBuffer.length)
        XCTAssertFalse(session.releaseMemory(for: .critical), "nothing left to drop")
        XCTAssertFalse(session.releaseMemory(for: .normal))
    }

    /// The touch-up masks go at critical only, and the session says so
    /// (`droppedTouchUpMasks`) until they are set again, so the editor
    /// knows to build them once pressure lifts (docs/Retouch.md §10).
    func testCriticalDropsTheTouchUpMasksAndSaysSo() throws {
        let (session, pipeline, _) = try openSession()
        _ = try renderLikeTheViewport(session, pipeline)
        let id = UUID()
        let summary = session.file.summary
        session.setTouchUpMasks(TouchUpMaskSet.fixture(sensorWidth: summary.rawWidth, sensorHeight: summary.rawHeight, faces: [
            (id: id, skin: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2), teeth: nil, eyes: []),
        ]))
        XCTAssertNotNil(session.touchUpMaskTexture(enabled: [id]))
        XCTAssertFalse(session.droppedTouchUpMasks)

        session.releaseMemory(for: .warning)
        XCTAssertTrue(session.hasTouchUpMasks, "a warning keeps them: a face pass to rebuild")
        XCTAssertFalse(session.droppedTouchUpMasks)
        XCTAssertGreaterThan(session.approximateBytesHeld, session.sensorBuffer.length, "the mask texture is still counted")

        session.releaseMemory(for: .critical)
        XCTAssertFalse(session.hasTouchUpMasks)
        XCTAssertTrue(session.droppedTouchUpMasks)
        XCTAssertNil(session.touchUpMaskTexture(enabled: [id]))
        XCTAssertEqual(session.approximateBytesHeld, session.sensorBuffer.length)
        session.setTouchUpMasks(nil)
        XCTAssertFalse(session.droppedTouchUpMasks, "cleared once the editor has acted on it")
    }

    /// A warning drops the heal cache with the pooled textures it points
    /// into: the next render heals again, and the one after is served.
    func testWarningClearsTheHealCache() throws {
        let (session, pipeline, _) = try openSession()
        var p = EditParameters()
        p.heals = [HealPatch(target: [0.5, 0.5], source: [0.6, 0.6], radius: 0.03)]
        func render() throws -> Bool {
            var info = RenderInfo(outputWidth: 0, outputHeight: 0, binQuads: 1, isFullResolution: false)
            _ = try pipeline.render(session, scale: .binned(quads: 2), parameters: p, info: &info)
            return info.healWasCached
        }
        XCTAssertFalse(try render())
        XCTAssertTrue(try render())
        session.releaseMemory(for: .warning)
        XCTAssertFalse(try render(), "healed again after the warning")
        XCTAssertTrue(try render())
        session.releaseMemory(for: .critical)
        XCTAssertFalse(try render(), "and after critical")
    }

    // MARK: - Footprint benchmark

    /// Process footprint of a session through a viewport's life and each
    /// release. Numbers depend on the Mac and on when Metal returns freed
    /// memory, so this prints rather than asserts; run it when changing
    /// what the session pools or releases. On an M-series Mac with the D750
    /// sample, a half-frame 100% tile took the footprint to about +470 MB
    /// and a warning brought it back to about +60 MB:
    ///     LATENT_MEMORY_BENCHMARK=1 swift test --filter MemoryPressureTests
    func testFootprintBenchmark() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LATENT_MEMORY_BENCHMARK"] == "1",
                          "set LATENT_MEMORY_BENCHMARK=1 to measure")
        func megabytes() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return Double(info.phys_footprint) / 1e6
        }
        let start = megabytes()
        func report(_ step: String, _ session: ImageSession) {
            print(String(format: "memory: %-28@ footprint +%5.0f MB, session reports %5.0f MB", step,
                         megabytes() - start, Double(session.approximateBytesHeld) / 1e6))
        }
        let (session, pipeline, _) = try openSession()
        report("opened", session)
        try autoreleasepool {
            _ = try pipeline.render(session, scale: .binned(quads: 2), parameters: .neutral)
        }
        report("preview rendered", session)
        try autoreleasepool {
            let w = session.file.summary.rawWidth, h = session.file.summary.rawHeight
            _ = try pipeline.render(session, scale: .region(x: w / 4, y: h / 4, width: w / 2, height: h / 2),
                                    parameters: .neutral)
        }
        report("half-frame 100% tile", session)
        session.releaseMemory(for: .warning)
        report("after warning", session)
        // Metal hands freed textures back to the system a moment later, so
        // the footprint right after a release still counts most of them.
        Thread.sleep(forTimeInterval: 2)
        report("2 s after warning", session)
        session.releaseMemory(for: .critical)
        report("after critical", session)
    }
}
