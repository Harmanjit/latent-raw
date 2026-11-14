import Foundation
import Metal
import Synchronization

/// Hot pixel removal (docs/wiki/Develop.md, "Hot Pixels"): stuck or hot
/// photosites, which long exposures and astro frames show as single
/// bright dots of pure red, green or blue, found on the Bayer sensor plane
/// and replaced before white balance and demosaic spread them into a
/// coloured cross (Shaders/HotPixels.metal).
///
/// Each photosite is compared with its eight nearest neighbours of the
/// same colour (two photosites away on the mosaic). A pixel far brighter
/// than them is replaced by their median. Sensor Dust removes dust
/// shadows, which are many pixels wide; this is for single photosites.
///
/// Absent from the edit means off, so every edit older than it renders
/// exactly as before. Never for a linear source: a JPEG, TIFF or merged
/// DNG has no mosaic left to test.
public struct HotPixelRemoval: Codable, Equatable, Hashable, Sendable {
    /// Which pixels count as defects.
    public enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Only a pixel brighter than every one of its neighbours by the
        /// threshold: an isolated stuck or hot photosite. Leaves fine
        /// bright detail (a star, a glint) that spans several pixels alone.
        case stuck
        /// Also a pixel brighter than its neighbours' median by the
        /// threshold, even when one or two neighbours are bright too:
        /// warm pixels in clusters and the brighter outliers of long
        /// exposure noise are dimmed to the median as well.
        case outliers

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .stuck: return "Stuck Pixels Only"
            case .outliers: return "Also Dim Outliers"
            }
        }

        /// The kernel's switch (HotPixels.metal).
        var gpuIndex: UInt32 { self == .stuck ? 0 : 1 }
    }

    /// 0 … 100: how much brighter than its neighbours a photosite must be
    /// to be replaced. Lower finds more.
    public var threshold: Float
    public var mode: Mode

    public init(threshold: Float = HotPixelRemoval.defaultThreshold, mode: Mode = .stuck) {
        self.threshold = threshold
        self.mode = mode
    }

    public static let defaultThreshold: Float = 50

    private enum CodingKeys: String, CodingKey { case threshold, mode }

    /// Lenient: a missing threshold keeps the default and an unknown mode
    /// (a later build's) reads as Stuck Pixels Only.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threshold = try c.decodeIfPresent(Float.self, forKey: .threshold) ?? Self.defaultThreshold
        let raw = try c.decodeIfPresent(String.self, forKey: .mode) ?? Mode.stuck.rawValue
        mode = Mode(rawValue: raw) ?? .stuck
    }

    /// A threshold from a file brought into 0…100.
    public var sanitized: HotPixelRemoval {
        HotPixelRemoval(threshold: threshold.isFinite ? min(max(threshold, 0), 100) : Self.defaultThreshold,
                        mode: mode)
    }

    /// How far above its neighbours, as a fraction of the sensor's range
    /// above black, a photosite must be to count: 1 % at threshold 0, up
    /// to 40 % at 100, rising slowly at first so the low end is fine-grained.
    public var margin: Float {
        let t = sanitized.threshold / 100
        return 0.01 + 0.39 * t * t
    }

    /// The Swift twin of the kernel's test, for one photosite with value
    /// `v` and its eight same-colour neighbours (all as fractions of the
    /// range above black): the value it is replaced with, or nil when it
    /// is left alone.
    public func replacement(for v: Float, neighbours: [Float]) -> Float? {
        guard neighbours.count == 8 else { return nil }
        let sorted = neighbours.sorted()
        let median = 0.5 * (sorted[3] + sorted[4])
        let m = margin
        let isDefect: Bool
        switch mode {
        case .stuck: isDefect = v - sorted[7] > m
        case .outliers: isDefect = v - sorted[7] > m || (v - median > m && v > 2 * median)
        }
        return isDefect ? median : nil
    }
}

/// Mirror of `HotPixelParamsGPU` in HotPixels.metal.
struct HotPixelParamsGPU {
    var rawWidth: UInt32
    var rawHeight: UInt32
    var blackLevel: Float
    var whiteLevel: Float
    var margin: Float
    var mode: UInt32
}

/// The sensor plane with hot pixels replaced, made once per setting and
/// kept on the session (`ImageSession.hotPixels`), and how many it fixed.
final class HotPixelCleanPlane: @unchecked Sendable {
    let removal: HotPixelRemoval
    let buffer: MTLBuffer
    let fixed: Int

    init(removal: HotPixelRemoval, buffer: MTLBuffer, fixed: Int) {
        self.removal = removal
        self.buffer = buffer
        self.fixed = fixed
    }
}

/// Runs the hot pixel kernel over the whole sensor plane.
enum HotPixelStage {
    /// The removal a render of `session` with `p` applies: the edit's,
    /// sanitised, for a Bayer raw; nil for none or for a linear source.
    static func activeRemoval(session: ImageSession, parameters p: EditParameters) -> HotPixelRemoval? {
        guard session.sourceKind == .bayer, let removal = p.hotPixels else { return nil }
        return removal.sanitized
    }

    /// The sensor buffer a render reads: the session's own, or its plane
    /// with `removal` applied, made now (one dispatch over the plane, on
    /// its own command buffer, waited for) if the session doesn't hold it
    /// for this setting already. The whole plane rather than the render's
    /// region, so a 100 % tile, the preview and an export all replace
    /// exactly the same photosites and the count is the frame's.
    static func sensorBuffer(session: ImageSession, removal: HotPixelRemoval?, gpu: GPUContext) throws -> MTLBuffer {
        guard let removal else { return session.sensorBuffer }
        if let held = session.hotPixels.withLock({ $0 }), held.removal == removal { return held.buffer }
        let clean = try makeCleanPlane(session: session, removal: removal, gpu: gpu)
        session.hotPixels.withLock { $0 = clean }
        return clean.buffer
    }

    static func makeCleanPlane(session: ImageSession, removal: HotPixelRemoval,
                               gpu: GPUContext) throws -> HotPixelCleanPlane {
        let summary = session.file.summary
        let w = summary.rawWidth, h = summary.rawHeight
        let length = max(1, w * h * MemoryLayout<UInt16>.size)
        // Shared, like the sensor buffer it stands in for (unified memory
        // costs nothing for it), so a test can read the result back.
        guard let output = gpu.device.makeBuffer(length: length, options: .storageModeShared),
              let counter = gpu.device.makeBuffer(length: 4, options: .storageModeShared) else {
            throw RenderError.gpuBufferAllocationFailed
        }
        counter.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        let pso = try gpu.lazyPipeline(.hotPixelsRemove)
        guard let cmd = gpu.commandQueue.makeCommandBuffer(), let encoder = cmd.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        var params = HotPixelParamsGPU(rawWidth: UInt32(w), rawHeight: UInt32(h),
                                       blackLevel: summary.blackLevel, whiteLevel: summary.whiteLevel,
                                       margin: removal.margin, mode: removal.mode.gpuIndex)
        encoder.setComputePipelineState(pso)
        encoder.setBuffer(session.sensorBuffer, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<HotPixelParamsGPU>.stride, index: 2)
        encoder.setBuffer(counter, offset: 0, index: 3)
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        guard cmd.status == .completed else { throw RenderError.commandBufferFailed }
        let fixed = Int(counter.contents().load(as: UInt32.self))
        return HotPixelCleanPlane(removal: removal, buffer: output, fixed: fixed)
    }
}

extension ImageSession {
    /// How many photosites the last render with `removal` replaced, or nil
    /// when no render has applied that setting yet (or it was released).
    /// What the Hot Pixels section's "N pixels fixed" reads.
    public func hotPixelsFixed(for removal: HotPixelRemoval?) -> Int? {
        guard let removal = removal?.sanitized else { return nil }
        return hotPixels.withLock { held in held.flatMap { $0.removal == removal ? $0.fixed : nil } }
    }
}
