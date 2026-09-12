import Foundation
import Metal
import simd
import RawCore
import ColorKit

public enum RenderError: Error, CustomStringConvertible {
    case unsupportedCFAForV1
    case gpuBufferAllocationFailed
    case commandBufferFailed
    case noCameraProfile(camera: String)

    public var description: String {
        switch self {
        case .unsupportedCFAForV1:
            return "Only Bayer sensors are supported in v1 (DESIGN.md §9.1)"
        case .gpuBufferAllocationFailed:
            return "Failed to allocate a GPU buffer or texture"
        case .commandBufferFailed:
            return "GPU command buffer failed"
        case .noCameraProfile(let camera):
            return "LibRaw has no colour characterization for '\(camera)'"
        }
    }
}

/// How much of the sensor's resolution to actually process (DESIGN.md §8.2).
public enum RenderScale: Sendable {
    /// Process every photosite. For export, and for 100% zoom.
    case full
    /// Process only as much as needed to fill `maxDimension` pixels on the
    /// long edge.
    case fitting(maxDimension: Int)
}

/// Which demosaic algorithm to use for full-resolution renders.
///
/// This has no effect on fit-to-window rendering: the binned path collapses
/// whole Bayer quads into single pixels and never interpolates at all, so
/// there's nothing for a demosaic algorithm to do. The choice matters at
/// 100% zoom and on export.
public enum DemosaicMethod: String, Sendable, CaseIterable {
    /// Fast, and visibly wrong on any edge that isn't axis-aligned —
    /// diagonal edges pick up a zipper of alternating colour. Kept as a
    /// correctness baseline and a speed comparison.
    case bilinear
    /// Ratio Corrected Demosaicing, ported from RawTherapee. Finds the
    /// local direction of detail and interpolates along it.
    case rcd

    public var displayName: String {
        switch self {
        case .bilinear: return "Bilinear (fast)"
        case .rcd:      return "RCD (quality)"
        }
    }
}

/// The user-adjustable parameters of a render.
///
/// This is the seed of the edit stack that DESIGN.md §5.6 serializes to
/// JSON and stores in the XMP sidecar.
public struct EditParameters: Sendable, Equatable {
    /// Which illuminant to treat as neutral. Defaults to as-shot.
    public var whiteBalance: ColorKit.WhiteBalance
    /// Exposure adjustment in stops. 0 is as-shot.
    public var exposureEV: Float
    /// Tone curve contrast.
    public var contrast: Float
    /// Scene-linear value mapped to 0.5 output.
    public var greyPoint: Float
    /// How strongly clipped highlights are pulled back toward neutral.
    public var highlightRecovery: Float
    /// Where highlight reconstruction starts, as a fraction of clip level.
    public var highlightThreshold: Float
    /// Demosaic algorithm for full-resolution renders.
    public var demosaic: DemosaicMethod
    /// Colour space the render is encoded into.
    public var outputSpace: ColorKit.OutputSpace

    public init(whiteBalance: ColorKit.WhiteBalance = .asShot,
                exposureEV: Float = 0,
                contrast: Float = 1.5,
                greyPoint: Float = 0.1845,
                highlightRecovery: Float = 1.0,
                highlightThreshold: Float = 0.85,
                demosaic: DemosaicMethod = .rcd,
                outputSpace: ColorKit.OutputSpace = .sRGB) {
        self.whiteBalance = whiteBalance
        self.exposureEV = exposureEV
        self.contrast = contrast
        self.greyPoint = greyPoint
        self.highlightRecovery = highlightRecovery
        self.highlightThreshold = highlightThreshold
        self.demosaic = demosaic
        self.outputSpace = outputSpace
    }

    public static let neutral = EditParameters()

    public static func == (a: EditParameters, b: EditParameters) -> Bool {
        a.whiteBalance == b.whiteBalance
            && a.exposureEV == b.exposureEV && a.contrast == b.contrast
            && a.greyPoint == b.greyPoint
            && a.highlightRecovery == b.highlightRecovery
            && a.highlightThreshold == b.highlightThreshold
            && a.demosaic == b.demosaic
            && String(describing: a.outputSpace) == String(describing: b.outputSpace)
    }
}

/// Describes what a given render actually did.
public struct RenderInfo: Sendable {
    public let outputWidth: Int
    public let outputHeight: Int
    public let binQuads: Int
    public let isFullResolution: Bool
    /// nil when the binned path ran, since it doesn't demosaic at all.
    public let demosaicUsed: DemosaicMethod?
    public var usedBinnedPath: Bool { !isFullResolution }

    public init(outputWidth: Int, outputHeight: Int, binQuads: Int,
                isFullResolution: Bool, demosaicUsed: DemosaicMethod? = nil) {
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.binQuads = binQuads
        self.isFullResolution = isFullResolution
        self.demosaicUsed = demosaicUsed
    }
}

/// The render pipeline: raw sensor data to a display-ready image.
///
/// Current stages (DESIGN.md §8.1 numbering): 1 raw levels, 2 highlight
/// reconstruction, 3 white balance, 4 demosaic, 5 camera matrix,
/// 6 exposure, 9 tone mapping, 13 output transform. Still missing: lens
/// corrections, denoise, local adjustments, grading, sharpening.
public final class RenderPipeline {
    let gpu: GPUContext

    public init(gpu: GPUContext) {
        self.gpu = gpu
    }

    @discardableResult
    public func render(_ session: ImageSession,
                        scale: RenderScale = .full,
                        parameters: EditParameters = .neutral,
                        info: UnsafeMutablePointer<RenderInfo>? = nil) throws -> MTLTexture {
        let summary = session.file.summary
        guard case .bayer(let order) = summary.cfaPattern else {
            throw RenderError.unsupportedCFAForV1
        }
        guard let cameraToWorking = session.cameraToWorkingMatrix else {
            throw RenderError.noCameraProfile(camera: summary.cameraModel)
        }

        let multipliers = session.multipliers(for: parameters.whiteBalance)
        let rawW = summary.rawWidth
        let rawH = summary.rawHeight
        let binQuads = Self.binQuads(rawWidth: rawW, rawHeight: rawH, scale: scale)

        let cameraRGB: MTLTexture
        let renderInfo: RenderInfo
        if binQuads <= 0 {
            cameraRGB = try renderFullResolution(session: session, order: order,
                                                  multipliers: multipliers,
                                                  method: parameters.demosaic)
            renderInfo = RenderInfo(outputWidth: cameraRGB.width,
                                     outputHeight: cameraRGB.height,
                                     binQuads: 1, isFullResolution: true,
                                     demosaicUsed: parameters.demosaic)
        } else {
            cameraRGB = try renderBinned(session: session, order: order,
                                          binQuads: binQuads, multipliers: multipliers)
            renderInfo = RenderInfo(outputWidth: cameraRGB.width,
                                     outputHeight: cameraRGB.height,
                                     binQuads: binQuads, isFullResolution: false,
                                     demosaicUsed: nil)
        }

        let final = try applyColorAndTone(session: session,
                                           input: cameraRGB,
                                           cameraToWorking: cameraToWorking,
                                           multipliers: multipliers,
                                           parameters: parameters)
        info?.pointee = renderInfo
        return final
    }

    /// Chooses how many 2x2 Bayer quads to collapse per output pixel.
    /// Returns 0 to mean "use the full-resolution path".
    static func binQuads(rawWidth: Int, rawHeight: Int, scale: RenderScale) -> Int {
        switch scale {
        case .full:
            return 0
        case .fitting(let maxDimension):
            guard maxDimension > 0 else { return 0 }
            let longEdge = max(rawWidth, rawHeight)
            guard longEdge > maxDimension else { return 0 }
            return max(0, (longEdge / maxDimension) / 2)
        }
    }

    // MARK: - Colour stage

    private func applyColorAndTone(session: ImageSession,
                                    input: MTLTexture,
                                    cameraToWorking: simd_float3x3,
                                    multipliers: SIMD4<Float>,
                                    parameters: EditParameters) throws -> MTLTexture {
        let output = try session.texture(width: input.width, height: input.height,
                                          pixelFormat: .rgba16Float, role: .display)

        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }

        encoder.setComputePipelineState(gpu.colorAndTonePSO)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)

        var camToWorking = cameraToWorking
        var workingToOut = ColorKit.workingToOutput(parameters.outputSpace)
        var exposureScale = powf(2.0, parameters.exposureEV)
        var contrast = parameters.contrast
        var greyPoint = parameters.greyPoint

        // Each channel saturates at its white balance multiplier, so these
        // move when the user changes temperature — using as-shot values
        // would break highlight recovery the moment the slider was touched.
        var clipLevel = SIMD3<Float>(multipliers.x, multipliers.y, multipliers.z)
        var highlightThreshold = parameters.highlightThreshold
        var highlightStrength = parameters.highlightRecovery

        encoder.setBytes(&camToWorking, length: MemoryLayout<simd_float3x3>.size, index: 0)
        encoder.setBytes(&workingToOut, length: MemoryLayout<simd_float3x3>.size, index: 1)
        encoder.setBytes(&exposureScale, length: 4, index: 2)
        encoder.setBytes(&contrast, length: 4, index: 3)
        encoder.setBytes(&greyPoint, length: 4, index: 4)
        encoder.setBytes(&clipLevel, length: MemoryLayout<SIMD3<Float>>.size, index: 5)
        encoder.setBytes(&highlightThreshold, length: 4, index: 6)
        encoder.setBytes(&highlightStrength, length: 4, index: 7)

        dispatch(encoder, pso: gpu.colorAndTonePSO, width: input.width, height: input.height)
        encoder.endEncoding()

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        if cmdBuffer.status == .error { throw RenderError.commandBufferFailed }
        return output
    }

    // MARK: - Full-resolution demosaic

    private func renderFullResolution(session: ImageSession, order: UInt8,
                                       multipliers: SIMD4<Float>,
                                       method: DemosaicMethod) throws -> MTLTexture {
        let cfaTex = try prepareCFA(session: session, multipliers: multipliers, order: order)
        switch method {
        case .bilinear:
            return try demosaicBilinear(session: session, cfa: cfaTex, order: order)
        case .rcd:
            return try demosaicRCD(session: session, cfa: cfaTex, order: order)
        }
    }

    /// Stages 1 and 3: black/white levels and white balance, producing the
    /// single-channel CFA plane both demosaicers consume.
    ///
    /// 32-bit float rather than 16: RCD compares gradients built from
    /// differences of neighbouring samples, and half precision's ~1e-3
    /// relative error on those differences is enough to flip a directional
    /// decision and produce visible artifacts.
    private func prepareCFA(session: ImageSession, multipliers: SIMD4<Float>,
                             order: UInt8) throws -> MTLTexture {
        let summary = session.file.summary
        let w = summary.rawWidth, h = summary.rawHeight
        let cfaTex = try session.texture(width: w, height: h, pixelFormat: .r32Float, role: .cfa)

        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        encoder.setComputePipelineState(gpu.whiteBalanceBlackLevelPSO)
        encoder.setBuffer(session.sensorBuffer, offset: 0, index: 0)
        var rawWidth = UInt32(w)
        var black = summary.blackLevel
        var white = summary.whiteLevel
        var mul = multipliers
        var order_ = order
        encoder.setBytes(&rawWidth, length: 4, index: 1)
        encoder.setBytes(&black, length: 4, index: 2)
        encoder.setBytes(&white, length: 4, index: 3)
        encoder.setBytes(&mul, length: 16, index: 4)
        encoder.setBytes(&order_, length: 1, index: 5)
        encoder.setTexture(cfaTex, index: 0)
        dispatch(encoder, pso: gpu.whiteBalanceBlackLevelPSO, width: w, height: h)
        encoder.endEncoding()

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        if cmdBuffer.status == .error { throw RenderError.commandBufferFailed }
        return cfaTex
    }

    private func demosaicBilinear(session: ImageSession, cfa: MTLTexture,
                                   order: UInt8) throws -> MTLTexture {
        let rgbTex = try session.texture(width: cfa.width, height: cfa.height,
                                          pixelFormat: .rgba16Float, role: .cameraRGB)
        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        encoder.setComputePipelineState(gpu.demosaicBilinearPSO)
        encoder.setTexture(cfa, index: 0)
        var order_ = order
        encoder.setBytes(&order_, length: 1, index: 0)
        encoder.setTexture(rgbTex, index: 1)
        dispatch(encoder, pso: gpu.demosaicBilinearPSO, width: cfa.width, height: cfa.height)
        encoder.endEncoding()

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        if cmdBuffer.status == .error { throw RenderError.commandBufferFailed }
        return rgbTex
    }

    /// RCD, as six dependent passes (see RCD.metal for the algorithm).
    ///
    /// They can't be fused: each stage reads its predecessor's
    /// *neighbourhood*, and GPU threads can't see each other's results
    /// within a dispatch. All six go into one command buffer, so the driver
    /// inserts the barriers between them and there's only one CPU/GPU
    /// round trip for the whole thing.
    ///
    /// The last two passes ping-pong between two RGB textures rather than
    /// reading and writing one. Their reads and writes touch disjoint pixel
    /// positions, but Metal still requires separate textures unless the
    /// texture is declared read_write, and the extra buffer is cheaper than
    /// the complexity.
    private func demosaicRCD(session: ImageSession, cfa: MTLTexture,
                              order: UInt8) throws -> MTLTexture {
        let w = cfa.width, h = cfa.height

        let vhDir = try session.texture(width: w, height: h, pixelFormat: .r16Float, role: .rcdVHDir)
        let lowPass = try session.texture(width: w, height: h, pixelFormat: .r32Float, role: .rcdLowPass)
        let diagonal = try session.texture(width: w, height: h, pixelFormat: .rg32Float, role: .rcdDiagonal)
        let pqDir = try session.texture(width: w, height: h, pixelFormat: .r16Float, role: .rcdPQDir)
        let rgbA = try session.texture(width: w, height: h, pixelFormat: .rgba16Float, role: .cameraRGB)
        let rgbB = try session.texture(width: w, height: h, pixelFormat: .rgba16Float, role: .rcdScratch)

        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer() else {
            throw RenderError.commandBufferFailed
        }

        func pass(_ pso: MTLComputePipelineState,
                   textures: [MTLTexture],
                   passOrder: Bool = false) throws {
            guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
                throw RenderError.commandBufferFailed
            }
            encoder.setComputePipelineState(pso)
            for (index, texture) in textures.enumerated() {
                encoder.setTexture(texture, index: index)
            }
            if passOrder {
                var order_ = order
                encoder.setBytes(&order_, length: 1, index: 0)
            }
            dispatch(encoder, pso: pso, width: w, height: h)
            encoder.endEncoding()
        }

        // 1. Vertical/horizontal directional discrimination.
        try pass(gpu.rcdDirectionsVHPSO, textures: [cfa, vhDir])
        // 2. Local average, for the ratio correction in step 3.
        try pass(gpu.rcdLowPassPSO, textures: [cfa, lowPass])
        // 3. Green everywhere.
        try pass(gpu.rcdGreenPSO, textures: [cfa, vhDir, lowPass, rgbA], passOrder: true)
        // 4. Diagonal statistics, then diagonal discrimination.
        try pass(gpu.rcdDiagonalStatsPSO, textures: [cfa, diagonal])
        try pass(gpu.rcdDirectionsPQPSO, textures: [diagonal, pqDir])
        // 5. Red at blue sites and blue at red sites.
        try pass(gpu.rcdRedBlueAtOppositePSO, textures: [rgbA, pqDir, rgbB], passOrder: true)
        // 6. Red and blue at green sites.
        try pass(gpu.rcdRedBlueAtGreenPSO, textures: [rgbB, vhDir, rgbA], passOrder: true)

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        if cmdBuffer.status == .error { throw RenderError.commandBufferFailed }
        return rgbA
    }

    // MARK: - Binned (viewport) path

    /// One fused pass straight from the sensor buffer to a small RGB
    /// texture, skipping demosaicing entirely — a Bayer quad already
    /// contains one red, one blue and two greens, so at reduced resolution
    /// there's nothing to interpolate.
    ///
    /// This kernel reads every sensor photosite regardless of `binQuads`:
    /// a larger factor means more samples per thread and proportionally
    /// fewer threads. Total reads are constant, which is why heavier
    /// binning shows diminishing returns — the cost floor is moving the
    /// sensor data, not the arithmetic.
    private func renderBinned(session: ImageSession, order: UInt8, binQuads: Int,
                               multipliers: SIMD4<Float>) throws -> MTLTexture {
        let summary = session.file.summary
        let rawW = summary.rawWidth, rawH = summary.rawHeight
        let span = binQuads * 2
        let outW = max(1, rawW / span)
        let outH = max(1, rawH / span)

        let rgbTex = try session.texture(width: outW, height: outH,
                                          pixelFormat: .rgba16Float, role: .cameraRGB)
        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }

        encoder.setComputePipelineState(gpu.demosaicBinnedPSO)
        encoder.setBuffer(session.sensorBuffer, offset: 0, index: 0)
        var rawWidth = UInt32(rawW)
        var rawHeight = UInt32(rawH)
        var black = summary.blackLevel
        var white = summary.whiteLevel
        var mul = multipliers
        var order_ = order
        var quads = UInt32(binQuads)
        encoder.setBytes(&rawWidth, length: 4, index: 1)
        encoder.setBytes(&rawHeight, length: 4, index: 2)
        encoder.setBytes(&black, length: 4, index: 3)
        encoder.setBytes(&white, length: 4, index: 4)
        encoder.setBytes(&mul, length: 16, index: 5)
        encoder.setBytes(&order_, length: 1, index: 6)
        encoder.setBytes(&quads, length: 4, index: 7)
        encoder.setTexture(rgbTex, index: 0)
        dispatch(encoder, pso: gpu.demosaicBinnedPSO, width: outW, height: outH)
        encoder.endEncoding()

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        if cmdBuffer.status == .error { throw RenderError.commandBufferFailed }
        return rgbTex
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pso: MTLComputePipelineState,
                           width: Int, height: Int) {
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        let threadsPerGroup = MTLSize(width: tw, height: th, depth: 1)
        let groups = MTLSize(width: (width + tw - 1) / tw,
                              height: (height + th - 1) / th,
                              depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }
}
