import Foundation
import CoreGraphics
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
    /// Process every photosite of the whole image. For export.
    case full
    /// Process only as much as needed to fill `maxDimension` pixels on the
    /// long edge. Picks a binning factor, or full resolution if the sensor
    /// is already small enough.
    case fitting(maxDimension: Int)
    /// Collapse `quads` x `quads` Bayer quads into each output pixel,
    /// covering the whole image. The viewport uses this whenever it's
    /// zoomed out far enough that full detail would be wasted.
    case binned(quads: Int)
    /// Full resolution, but only the given sensor rectangle. This is the
    /// "render only the visible tiles" path for 100% zoom: a 24 MP file on
    /// a 4 MP display needs 4 MP of demosaicing, not 24. The origin is
    /// snapped to even coordinates (see WhiteBalance.metal) and the rect is
    /// clamped to the sensor; `RenderInfo.sensorRect` reports what was
    /// actually rendered.
    case region(x: Int, y: Int, width: Int, height: Int)
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

/// How the final pixels are encoded — which is about the *destination*,
/// not the edit, which is why it isn't part of EditParameters.
public struct RenderOutput: Sendable, Equatable {
    /// Primaries of the output.
    public var space: ColorKit.OutputSpace
    /// Tone-curve ceiling relative to paper white. 1 for SDR and files.
    public var headroom: Float
    /// Apply the sRGB curve and clamp to [0,1]? Files yes; an EDR screen
    /// buffer no — it wants linear light.
    public var encoded: Bool
    /// Run the tone curve? Off for analysis renders that want scene-linear
    /// values (exposure applied, nothing else).
    public var toneMapped: Bool

    public init(space: ColorKit.OutputSpace, headroom: Float = 1, encoded: Bool = true,
                toneMapped: Bool = true) {
        self.space = space
        self.headroom = headroom
        self.encoded = encoded
        self.toneMapped = toneMapped
    }

    /// Scene-linear working-space values: camera matrix and exposure
    /// applied, no tone curve, no encoding. What Auto adjustments and
    /// other analysis read.
    public static let sceneLinear = RenderOutput(space: .rec2020, headroom: 1,
                                                 encoded: false, toneMapped: false)

    /// An ordinary file: encoded, no headroom.
    public static func file(_ space: ColorKit.OutputSpace) -> RenderOutput {
        RenderOutput(space: space, headroom: 1, encoded: true)
    }

    /// An EDR CAMetalLayer configured for extended linear Display P3.
    public static func edrDisplay(headroom: Float) -> RenderOutput {
        RenderOutput(space: .displayP3, headroom: max(1, headroom), encoded: false)
    }

    public static func == (a: RenderOutput, b: RenderOutput) -> Bool {
        String(describing: a.space) == String(describing: b.space)
            && a.headroom == b.headroom && a.encoded == b.encoded
            && a.toneMapped == b.toneMapped
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
    /// The sensor-space rectangle the output texture covers. The whole
    /// sensor for full and binned renders (binned may fall a few pixels
    /// short on the right/bottom when the size isn't a multiple of the
    /// bin span); the clamped, snapped rectangle for region renders.
    /// The presenter uses this to place the texture on screen.
    public let sensorRect: CGRect
    /// True when the demosaic stage was skipped because the session had an
    /// identical result cached; only the colour/tone stage ran.
    public let demosaicWasCached: Bool
    public var usedBinnedPath: Bool { !isFullResolution }

    public init(outputWidth: Int, outputHeight: Int, binQuads: Int,
                isFullResolution: Bool, demosaicUsed: DemosaicMethod? = nil,
                sensorRect: CGRect = .zero, demosaicWasCached: Bool = false) {
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        self.binQuads = binQuads
        self.isFullResolution = isFullResolution
        self.demosaicUsed = demosaicUsed
        self.sensorRect = sensorRect
        self.demosaicWasCached = demosaicWasCached
    }
}

/// A resolved render plan: which path runs, and over what.
enum RenderPlan {
    case fullResolution(origin: (x: Int, y: Int), size: (width: Int, height: Int))
    case binned(quads: Int)
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

    /// `output` defaults to an encoded file in `parameters.outputSpace`,
    /// which is what export, the CLI and the tests want. The viewport
    /// passes `.edrDisplay(headroom:)` instead.
    @discardableResult
    public func render(_ session: ImageSession,
                        scale: RenderScale = .full,
                        parameters: EditParameters = .neutral,
                        output: RenderOutput? = nil,
                        info: UnsafeMutablePointer<RenderInfo>? = nil) throws -> MTLTexture {
        try renderStages(session, scale: scale, parameters: parameters,
                         output: output ?? .file(parameters.outputSpace),
                         cameraRGBOnly: false, info: info)
    }

    /// The demosaiced, white-balanced camera-space image — the pipeline
    /// stopped before the colour matrix. Linear, camera primaries. Used by
    /// analysis that needs to reason in the sensor's own colour space,
    /// such as grey-world white balance.
    public func renderCameraRGB(_ session: ImageSession,
                                 scale: RenderScale,
                                 parameters: EditParameters) throws -> MTLTexture {
        try renderStages(session, scale: scale, parameters: parameters,
                         output: .sceneLinear, cameraRGBOnly: true, info: nil)
    }

    private func renderStages(_ session: ImageSession,
                              scale: RenderScale,
                              parameters: EditParameters,
                              output: RenderOutput,
                              cameraRGBOnly: Bool,
                              info: UnsafeMutablePointer<RenderInfo>?) throws -> MTLTexture {
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
        let plan = Self.plan(rawWidth: rawW, rawHeight: rawH, scale: scale)

        // Every stage of this render is encoded into ONE command buffer and
        // submitted once. The GPU runs the stages back to back and the CPU
        // waits a single time at the end. Submitting each stage separately
        // (as this used to) added a full CPU-GPU round trip per stage.
        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer() else {
            throw RenderError.commandBufferFailed
        }

        // Stage cache (DESIGN.md §8.2): if the session already holds the
        // demosaiced result for exactly these inputs, skip straight to the
        // colour stage. Exposure and tone edits hit this every time; white
        // balance and zoom changes miss.
        let stageKey = Self.stageKey(plan: plan, multipliers: multipliers,
                                     demosaic: parameters.demosaic)
        let cached = session.cachedCameraRGB(for: stageKey)

        let cameraRGB: MTLTexture
        let renderInfo: RenderInfo
        let displayRole: ImageSession.TextureRole
        switch plan {
        case .fullResolution(let origin, let size):
            displayRole = .display
            cameraRGB = try cached ?? renderFullResolution(
                session: session, cmdBuffer: cmdBuffer, order: order,
                multipliers: multipliers, method: parameters.demosaic,
                origin: origin, size: size)
            renderInfo = RenderInfo(outputWidth: cameraRGB.width,
                                     outputHeight: cameraRGB.height,
                                     binQuads: 1, isFullResolution: true,
                                     demosaicUsed: parameters.demosaic,
                                     sensorRect: CGRect(x: origin.x, y: origin.y,
                                                        width: size.width, height: size.height),
                                     demosaicWasCached: cached != nil)
        case .binned(let quads):
            displayRole = .displayPreview
            cameraRGB = try cached ?? renderBinned(
                session: session, cmdBuffer: cmdBuffer, order: order,
                binQuads: quads, multipliers: multipliers)
            let span = quads * 2
            renderInfo = RenderInfo(outputWidth: cameraRGB.width,
                                     outputHeight: cameraRGB.height,
                                     binQuads: quads, isFullResolution: false,
                                     demosaicUsed: nil,
                                     sensorRect: CGRect(x: 0, y: 0,
                                                        width: cameraRGB.width * span,
                                                        height: cameraRGB.height * span),
                                     demosaicWasCached: cached != nil)
        }
        if cached == nil {
            session.storeCameraRGB(cameraRGB, for: stageKey)
        }

        if cameraRGBOnly {
            cmdBuffer.commit()
            cmdBuffer.waitUntilCompleted()
            if cmdBuffer.status == .error { throw RenderError.commandBufferFailed }
            info?.pointee = renderInfo
            return cameraRGB
        }

        let final = try applyColorAndTone(session: session, cmdBuffer: cmdBuffer,
                                           input: cameraRGB,
                                           outputRole: displayRole,
                                           cameraToWorking: cameraToWorking,
                                           multipliers: multipliers,
                                           parameters: parameters,
                                           output: output)

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        if cmdBuffer.status == .error { throw RenderError.commandBufferFailed }

        info?.pointee = renderInfo
        return final
    }

    static func stageKey(plan: RenderPlan, multipliers: SIMD4<Float>,
                         demosaic: DemosaicMethod) -> ImageSession.StageKey {
        switch plan {
        case .fullResolution(let origin, let size):
            return .init(isFullResolution: true, originX: origin.x, originY: origin.y,
                         width: size.width, height: size.height, quads: 0,
                         multipliers: multipliers, demosaic: demosaic)
        case .binned(let quads):
            // Demosaic method is irrelevant to binning; normalize it so a
            // method change doesn't needlessly miss the cache.
            return .init(isFullResolution: false, originX: 0, originY: 0,
                         width: 0, height: 0, quads: quads,
                         multipliers: multipliers, demosaic: .bilinear)
        }
    }

    /// Turns the requested scale into a concrete plan.
    static func plan(rawWidth: Int, rawHeight: Int, scale: RenderScale) -> RenderPlan {
        let whole = RenderPlan.fullResolution(origin: (0, 0), size: (rawWidth, rawHeight))
        switch scale {
        case .full:
            return whole

        case .fitting(let maxDimension):
            guard maxDimension > 0 else { return whole }
            let longEdge = max(rawWidth, rawHeight)
            guard longEdge > maxDimension else { return whole }
            let quads = (longEdge / maxDimension) / 2
            return quads >= 1 ? .binned(quads: quads) : whole

        case .binned(let quads):
            return .binned(quads: max(1, quads))

        case .region(let x, let y, let width, let height):
            // Even origin keeps the Bayer parity (see WhiteBalance.metal).
            // Clamp so the rectangle stays inside the sensor; shrink only
            // if the sensor itself is smaller than what was asked for.
            let w = max(2, min(width, rawWidth))
            let h = max(2, min(height, rawHeight))
            let ox = min(max(x, 0), rawWidth - w) & ~1
            let oy = min(max(y, 0), rawHeight - h) & ~1
            return .fullResolution(origin: (ox, oy), size: (w, h))
        }
    }

    // MARK: - Colour stage

    private func applyColorAndTone(session: ImageSession,
                                    cmdBuffer: MTLCommandBuffer,
                                    input: MTLTexture,
                                    outputRole: ImageSession.TextureRole,
                                    cameraToWorking: simd_float3x3,
                                    multipliers: SIMD4<Float>,
                                    parameters: EditParameters,
                                    output: RenderOutput) throws -> MTLTexture {
        let outputTexture = try session.texture(width: input.width, height: input.height,
                                                 pixelFormat: .rgba16Float, role: outputRole)

        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }

        encoder.setComputePipelineState(gpu.colorAndTonePSO)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(outputTexture, index: 1)

        var camToWorking = cameraToWorking
        var workingToOut = ColorKit.workingToOutput(output.space)
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
        var headroom = output.headroom
        var encode: UInt32 = output.encoded ? 1 : 0
        var toneMap: UInt32 = output.toneMapped ? 1 : 0
        encoder.setBytes(&headroom, length: 4, index: 8)
        encoder.setBytes(&encode, length: 4, index: 9)
        encoder.setBytes(&toneMap, length: 4, index: 10)

        dispatch(encoder, pso: gpu.colorAndTonePSO, width: input.width, height: input.height)
        encoder.endEncoding()
        return outputTexture
    }

    // MARK: - Full-resolution demosaic

    private func renderFullResolution(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                                       order: UInt8,
                                       multipliers: SIMD4<Float>,
                                       method: DemosaicMethod,
                                       origin: (x: Int, y: Int),
                                       size: (width: Int, height: Int)) throws -> MTLTexture {
        let cfaTex = try prepareCFA(session: session, cmdBuffer: cmdBuffer,
                                    multipliers: multipliers, order: order,
                                    origin: origin, size: size)
        switch method {
        case .bilinear:
            return try demosaicBilinear(session: session, cmdBuffer: cmdBuffer,
                                        cfa: cfaTex, order: order)
        case .rcd:
            return try demosaicRCD(session: session, cmdBuffer: cmdBuffer,
                                   cfa: cfaTex, order: order)
        }
    }

    /// Stages 1 and 3: black/white levels and white balance, producing the
    /// single-channel CFA plane both demosaicers consume.
    ///
    /// 32-bit float rather than 16: RCD compares gradients built from
    /// differences of neighbouring samples, and half precision's ~1e-3
    /// relative error on those differences is enough to flip a directional
    /// decision and produce visible artifacts.
    private func prepareCFA(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                             multipliers: SIMD4<Float>,
                             order: UInt8,
                             origin: (x: Int, y: Int),
                             size: (width: Int, height: Int)) throws -> MTLTexture {
        let summary = session.file.summary
        let w = size.width, h = size.height
        let cfaTex = try session.texture(width: w, height: h, pixelFormat: .r32Float, role: .cfa)

        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        encoder.setComputePipelineState(gpu.whiteBalanceBlackLevelPSO)
        encoder.setBuffer(session.sensorBuffer, offset: 0, index: 0)
        // The sensor buffer's row stride is always the full raw width,
        // even when only a sub-rectangle is being rendered.
        var rawWidth = UInt32(summary.rawWidth)
        var black = summary.blackLevel
        var white = summary.whiteLevel
        var mul = multipliers
        var order_ = order
        var originXY = SIMD2<UInt32>(UInt32(origin.x), UInt32(origin.y))
        encoder.setBytes(&rawWidth, length: 4, index: 1)
        encoder.setBytes(&black, length: 4, index: 2)
        encoder.setBytes(&white, length: 4, index: 3)
        encoder.setBytes(&mul, length: 16, index: 4)
        encoder.setBytes(&order_, length: 1, index: 5)
        encoder.setBytes(&originXY, length: 8, index: 6)
        encoder.setTexture(cfaTex, index: 0)
        dispatch(encoder, pso: gpu.whiteBalanceBlackLevelPSO, width: w, height: h)
        encoder.endEncoding()
        return cfaTex
    }

    private func demosaicBilinear(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                                   cfa: MTLTexture,
                                   order: UInt8) throws -> MTLTexture {
        let rgbTex = try session.texture(width: cfa.width, height: cfa.height,
                                          pixelFormat: .rgba16Float, role: .cameraRGB)
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        encoder.setComputePipelineState(gpu.demosaicBilinearPSO)
        encoder.setTexture(cfa, index: 0)
        var order_ = order
        encoder.setBytes(&order_, length: 1, index: 0)
        encoder.setTexture(rgbTex, index: 1)
        dispatch(encoder, pso: gpu.demosaicBilinearPSO, width: cfa.width, height: cfa.height)
        encoder.endEncoding()
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
    private func demosaicRCD(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                              cfa: MTLTexture,
                              order: UInt8) throws -> MTLTexture {
        let w = cfa.width, h = cfa.height

        let vhDir = try session.texture(width: w, height: h, pixelFormat: .r16Float, role: .rcdVHDir)
        let lowPass = try session.texture(width: w, height: h, pixelFormat: .r32Float, role: .rcdLowPass)
        let diagonal = try session.texture(width: w, height: h, pixelFormat: .rg32Float, role: .rcdDiagonal)
        let pqDir = try session.texture(width: w, height: h, pixelFormat: .r16Float, role: .rcdPQDir)
        let rgbA = try session.texture(width: w, height: h, pixelFormat: .rgba16Float, role: .cameraRGB)
        let rgbB = try session.texture(width: w, height: h, pixelFormat: .rgba16Float, role: .rcdScratch)

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
    private func renderBinned(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                               order: UInt8, binQuads: Int,
                               multipliers: SIMD4<Float>) throws -> MTLTexture {
        let summary = session.file.summary
        let rawW = summary.rawWidth, rawH = summary.rawHeight
        let span = binQuads * 2
        let outW = max(1, rawW / span)
        let outH = max(1, rawH / span)

        let rgbTex = try session.texture(width: outW, height: outH,
                                          pixelFormat: .rgba16Float, role: .cameraRGB)
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
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
