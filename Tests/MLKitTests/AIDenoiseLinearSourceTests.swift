import XCTest
import Metal
@testable import MLKit
@testable import PixelEngine
@testable import RawCore

/// The neural denoiser refuses linear sources (HDR merges and other
/// LinearRaw DNGs): it only handles values up to white.
final class AIDenoiseLinearSourceTests: XCTestCase {
    static let fixture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("PixelEngineTests/Fixtures/LinearDNG/merge-hdr-64x48.dng").path

    func testWorkerRefusesALinearSource() async throws {
        try XCTSkipUnless(AIDenoiser.isAvailable, "NAFNet package not bundled")
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: Self.fixture), gpu: gpu)
        XCTAssertFalse(session.supportsAIDenoise)
        let denoiser = try await AIDenoiser.load(.standard)
        do {
            try await AIDenoiseWorker.run(session: session, pipeline: RenderPipeline(gpu: gpu), gpu: gpu,
                                          denoiser: denoiser)
            XCTFail("the worker ran on a linear source")
        } catch AIDenoiseError.linearSource {
            // Refused, and nothing stored for the pipeline to blend.
            XCTAssertNil(session.aiDenoisedCameraRGB)
        }
    }
}
