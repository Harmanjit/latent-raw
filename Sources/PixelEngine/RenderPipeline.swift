import Foundation
import CoreGraphics
import Metal
import simd
import RawCore
import ColorKit
import LensKit

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
    /// Noise reduction strengths, 0 (off) to 1.
    public var denoiseLuminance: Float
    public var denoiseColor: Float
    /// Unsharp-mask sharpening: amount 0 (off) to 2, radius in sensor
    /// pixels (Gaussian sigma), threshold in perceptual luminance units
    /// below which detail is left untouched.
    public var sharpenAmount: Float
    public var sharpenRadius: Float
    public var sharpenThreshold: Float
    /// Lens corrections from the matched profile, each switchable.
    public var lensDistortion: Bool
    public var lensTCA: Bool
    public var lensVignetting: Bool
    /// Manual corrections, applied on top of (or instead of) the profile:
    /// distortion as a poly3 k1 (negative = bulge inward), vignetting as
    /// a corner brightening amount.
    public var manualDistortion: Float
    public var manualVignetting: Float
    /// Colour grading.
    public var toneCurve: ToneCurve
    public var hsl: HSLAdjustments
    public var splitToning: SplitToning
    /// Local adjustments, applied in order.
    public var locals: [LocalAdjustment]
    /// Crop and straighten. Not a pipeline stage: the presenter and the
    /// exporter sample through it (see `CropFrame`).
    public var crop: CropParameters
    /// Spot removal patches, applied in order in camera space.
    public var heals: [HealPatch]
    /// Presence: local contrast at two scales and haze removal, −1…1.
    public var texture: Float
    public var clarity: Float
    public var dehaze: Float
    /// Saturation that favours muted colours and spares skin, −1…1.
    public var vibrance: Float
    /// Manual chromatic-aberration cleanup, 0…1 each.
    public var defringePurple: Float
    public var defringeGreen: Float
    /// Keystone correction, applied with the lens corrections.
    public var perspective: PerspectiveCorrection
    /// Neural noise reduction strength, 0 (off) … 1. The model's output
    /// is computed once per image (MLKit) and blended in at this weight.
    public var aiDenoise: Float

    public init(whiteBalance: ColorKit.WhiteBalance = .asShot,
                exposureEV: Float = 0,
                contrast: Float = 1.5,
                greyPoint: Float = 0.1845,
                highlightRecovery: Float = 1.0,
                highlightThreshold: Float = 0.85,
                demosaic: DemosaicMethod = .rcd,
                outputSpace: ColorKit.OutputSpace = .sRGB,
                denoiseLuminance: Float = 0,
                denoiseColor: Float = 0,
                sharpenAmount: Float = 0,
                sharpenRadius: Float = 1.0,
                sharpenThreshold: Float = 0.01,
                lensDistortion: Bool = true,
                lensTCA: Bool = true,
                lensVignetting: Bool = true,
                manualDistortion: Float = 0,
                manualVignetting: Float = 0,
                toneCurve: ToneCurve = .identity,
                hsl: HSLAdjustments = .neutral,
                splitToning: SplitToning = .neutral,
                locals: [LocalAdjustment] = [],
                crop: CropParameters = .none,
                heals: [HealPatch] = [],
                texture: Float = 0, clarity: Float = 0, dehaze: Float = 0,
                vibrance: Float = 0,
                defringePurple: Float = 0, defringeGreen: Float = 0,
                perspective: PerspectiveCorrection = .none,
                aiDenoise: Float = 0) {
        self.whiteBalance = whiteBalance
        self.exposureEV = exposureEV
        self.contrast = contrast
        self.greyPoint = greyPoint
        self.highlightRecovery = highlightRecovery
        self.highlightThreshold = highlightThreshold
        self.demosaic = demosaic
        self.outputSpace = outputSpace
        self.denoiseLuminance = denoiseLuminance
        self.denoiseColor = denoiseColor
        self.sharpenAmount = sharpenAmount
        self.sharpenRadius = sharpenRadius
        self.sharpenThreshold = sharpenThreshold
        self.lensDistortion = lensDistortion
        self.lensTCA = lensTCA
        self.lensVignetting = lensVignetting
        self.manualDistortion = manualDistortion
        self.manualVignetting = manualVignetting
        self.toneCurve = toneCurve
        self.hsl = hsl
        self.splitToning = splitToning
        self.locals = locals
        self.crop = crop
        self.heals = heals
        self.texture = texture; self.clarity = clarity; self.dehaze = dehaze
        self.vibrance = vibrance
        self.defringePurple = defringePurple; self.defringeGreen = defringeGreen
        self.perspective = perspective
        self.aiDenoise = aiDenoise
    }

    /// Whether the presence stage has anything to do.
    public var wantsLocalContrast: Bool {
        texture != 0 || clarity != 0 || dehaze != 0 || defringePurple > 0 || defringeGreen > 0
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
            && a.denoiseLuminance == b.denoiseLuminance && a.denoiseColor == b.denoiseColor
            && a.sharpenAmount == b.sharpenAmount && a.sharpenRadius == b.sharpenRadius
            && a.sharpenThreshold == b.sharpenThreshold
            && a.lensDistortion == b.lensDistortion && a.lensTCA == b.lensTCA
            && a.lensVignetting == b.lensVignetting
            && a.manualDistortion == b.manualDistortion && a.manualVignetting == b.manualVignetting
            && a.toneCurve == b.toneCurve && a.hsl == b.hsl && a.splitToning == b.splitToning
            && a.locals == b.locals && a.crop == b.crop && a.heals == b.heals
            && a.texture == b.texture && a.clarity == b.clarity && a.dehaze == b.dehaze
            && a.vibrance == b.vibrance
            && a.defringePurple == b.defringePurple && a.defringeGreen == b.defringeGreen
            && a.perspective == b.perspective && a.aiDenoise == b.aiDenoise
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
    /// Index into `EditParameters.locals` whose mask to paint as a red
    /// overlay, for editing. nil normally. A display concern, not an edit.
    public var maskOverlay: Int? = nil
    /// Soft-proof table to apply, and whether to flag clipped colours.
    public var proof: SoftProofLUT? = nil
    public var gamutWarning = false

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
            && a.toneMapped == b.toneMapped && a.maskOverlay == b.maskOverlay
            && a.proof?.id == b.proof?.id && a.gamutWarning == b.gamutWarning
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
/// Stage order is documented in DESIGN.md §8.1; `renderStages` is the
/// authoritative sequence.
public final class RenderPipeline {
    let gpu: GPUContext

    /// The most recent proof table as a texture, so a proofed render
    /// doesn't rebuild 143K texels every frame.
    private var proofTexture: (id: UUID, texture: MTLTexture)?
    private var placeholder3D: MTLTexture?

    public init(gpu: GPUContext) {
        self.gpu = gpu
    }

    private func proofTexture(for lut: SoftProofLUT?) -> MTLTexture? {
        if let lut {
            if let cached = proofTexture, cached.id == lut.id { return cached.texture }
            guard let texture = lut.makeTexture(device: gpu.device) else { return nil }
            proofTexture = (lut.id, texture)
            return texture
        }
        if placeholder3D == nil {
            let d = MTLTextureDescriptor()
            d.textureType = .type3D; d.pixelFormat = .rgba16Float
            d.width = 1; d.height = 1; d.depth = 1
            d.storageMode = .shared; d.usage = [.shaderRead]
            placeholder3D = gpu.device.makeTexture(descriptor: d)
        }
        return placeholder3D
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

        // How many sensor pixels each output pixel spans, for scaling the
        // detail stages so the preview predicts the full-size result.
        let binSpan: Float = renderInfo.isFullResolution ? 1 : Float(renderInfo.binQuads * 2)

        var colourInput = cameraRGB

        // Neural denoise: blend the session's cached full-frame result in,
        // re-binned and re-white-balanced to match this render.
        if parameters.aiDenoise > 0, let denoised = session.aiDenoisedCameraRGB {
            colourInput = try applyAIDenoise(session: session, cmdBuffer: cmdBuffer, input: cameraRGB,
                                             denoised: denoised, strength: parameters.aiDenoise,
                                             multipliers: multipliers, renderInfo: renderInfo,
                                             outputRole: displayRole == .display ? .aiDenoised : .aiDenoisedPreview)
        }

        // Stage 8: noise reduction, in camera space, before the matrix.
        if parameters.denoiseLuminance > 0 || parameters.denoiseColor > 0 {
            // colourInput, not cameraRGB: it may already carry the AI denoise blend.
            colourInput = try applyDenoise(session: session, cmdBuffer: cmdBuffer,
                                           input: colourInput, parameters: parameters,
                                           binSpan: binSpan)
        }

        // Spot removal, in camera space, before the lens stage moves pixels.
        let activeHeals = parameters.heals.filter {
            $0.targetBounds(sensorSize: CGSize(width: rawW, height: rawH)).intersects(renderInfo.sensorRect)
        }
        if !activeHeals.isEmpty {
            colourInput = try applyHeal(session: session, cmdBuffer: cmdBuffer, input: colourInput,
                                        patches: activeHeals, renderInfo: renderInfo, binSpan: binSpan)
        }

        // Stage 7: lens corrections, still in camera space.
        if Self.wantsLensCorrection(session: session, parameters: parameters) {
            colourInput = try applyLensCorrection(session: session, cmdBuffer: cmdBuffer,
                                                  input: colourInput, parameters: parameters,
                                                  renderInfo: renderInfo, binSpan: binSpan)
        }

        var final = try applyColorAndTone(session: session, cmdBuffer: cmdBuffer,
                                          input: colourInput,
                                          outputRole: displayRole,
                                          cameraToWorking: cameraToWorking,
                                          multipliers: multipliers,
                                          parameters: parameters,
                                          output: output,
                                          renderInfo: renderInfo, binSpan: binSpan)

        // Presence (texture, clarity, dehaze, defringe), display-referred,
        // before sharpening so the sharpener sees the final tonality.
        if parameters.wantsLocalContrast {
            final = try applyLocalContrast(session: session, cmdBuffer: cmdBuffer, input: final,
                                           outputRole: displayRole == .display ? .presence : .presencePreview,
                                           parameters: parameters, output: output,
                                           renderInfo: renderInfo, binSpan: binSpan)
        }

        // Stage 12: sharpening, on the display-referred result.
        if parameters.sharpenAmount > 0 {
            final = try applySharpen(session: session, cmdBuffer: cmdBuffer, input: final,
                                     outputRole: displayRole == .display ? .sharpened : .sharpenedPreview,
                                     parameters: parameters, output: output, binSpan: binSpan)
        }

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        if cmdBuffer.status == .error { throw RenderError.commandBufferFailed }

        info?.pointee = renderInfo
        return final
    }

    private static let identityLUT: [Float] = ToneCurve.identity.lookupTable()

    // MARK: - Lens corrections

    static func wantsLensCorrection(session: ImageSession, parameters p: EditParameters) -> Bool {
        if p.manualDistortion != 0 || p.manualVignetting != 0 || !p.perspective.isIdentity { return true }
        guard let c = session.lensCorrection else { return false }
        return (p.lensDistortion && c.distortion != nil)
            || (p.lensTCA && c.tca != nil)
            || (p.lensVignetting && c.vignetting != nil)
    }

    private func applyLensCorrection(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                                     input: MTLTexture, parameters p: EditParameters,
                                     renderInfo: RenderInfo, binSpan: Float) throws -> MTLTexture {
        let output = try session.texture(width: input.width, height: input.height,
                                         pixelFormat: .rgba16Float, role: .lensCorrected)
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        let c = session.lensCorrection
        let summary = session.file.summary

        var sensorSize = SIMD2<Float>(Float(summary.rawWidth), Float(summary.rawHeight))
        var tileOrigin = SIMD2<Float>(Float(renderInfo.sensorRect.origin.x),
                                      Float(renderInfo.sensorRect.origin.y))
        var span = binSpan
        var cropRatio = c?.cropRatio ?? 1
        let useDistortion = p.lensDistortion && c?.distortion != nil
        var autoScale = useDistortion ? (c?.autoScale ?? 1) : 1
        var distType: Int32 = 0
        var distTerms = SIMD3<Float>(0, 0, 0)
        if useDistortion, let d = c?.distortion {
            (distType, distTerms) = d.packed
        }
        var manualDist = p.manualDistortion
        var tcaOn: Int32 = (p.lensTCA && c?.tca != nil) ? 1 : 0
        var tcaRed = c?.tca?.red ?? SIMD3(0, 0, 1)
        var tcaBlue = c?.tca?.blue ?? SIMD3(0, 0, 1)
        var vigOn: Int32 = (p.lensVignetting && c?.vignetting != nil) ? 1 : 0
        var vig = c?.vignetting.map { SIMD3<Float>($0.k1, $0.k2, $0.k3) } ?? SIMD3(0, 0, 0)
        var manualVig = p.manualVignetting

        encoder.setComputePipelineState(gpu.lensCorrectPSO)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&sensorSize, length: 8, index: 0)
        encoder.setBytes(&tileOrigin, length: 8, index: 1)
        encoder.setBytes(&span, length: 4, index: 2)
        encoder.setBytes(&cropRatio, length: 4, index: 3)
        encoder.setBytes(&autoScale, length: 4, index: 4)
        encoder.setBytes(&distType, length: 4, index: 5)
        encoder.setBytes(&distTerms, length: 16, index: 6)
        encoder.setBytes(&manualDist, length: 4, index: 7)
        encoder.setBytes(&tcaOn, length: 4, index: 8)
        encoder.setBytes(&tcaRed, length: 16, index: 9)
        encoder.setBytes(&tcaBlue, length: 16, index: 10)
        encoder.setBytes(&vigOn, length: 4, index: 11)
        encoder.setBytes(&vig, length: 16, index: 12)
        encoder.setBytes(&manualVig, length: 4, index: 13)
        var perspective = p.perspective.inverseMatrix
        encoder.setBytes(&perspective, length: MemoryLayout<simd_float3x3>.size, index: 14)
        dispatch(encoder, pso: gpu.lensCorrectPSO, width: input.width, height: input.height)
        encoder.endEncoding()
        return output
    }

    // MARK: - Presence (texture, clarity, dehaze, defringe)

    /// Gaussian taps up to 65 wide (sigma ≤ ~10). Larger blurs run on a
    /// downsampled copy instead of a wider kernel.
    static func wideGaussianWeights(sigma: Float) -> [Float] {
        let s = max(sigma, 0.3)
        let half = min(Int((3 * s).rounded(.up)), 32)
        var weights = (-half...half).map { exp(-Float($0 * $0) / (2 * s * s)) }
        let sum = weights.reduce(0, +)
        weights = weights.map { $0 / sum }
        return weights
    }

    private func applyLocalContrast(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                                    input: MTLTexture, outputRole: ImageSession.TextureRole,
                                    parameters p: EditParameters, output: RenderOutput,
                                    renderInfo: RenderInfo, binSpan: Float) throws -> MTLTexture {
        let w = input.width, h = input.height
        let summary = session.file.summary
        let shortSide = Float(min(summary.rawWidth, summary.rawHeight))

        func pass(_ pso: MTLComputePipelineState, _ textures: [MTLTexture], width: Int, height: Int,
                  _ bind: (MTLComputeCommandEncoder) -> Void) throws {
            guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
                throw RenderError.commandBufferFailed
            }
            encoder.setComputePipelineState(pso)
            for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
            bind(encoder)
            dispatch(encoder, pso: pso, width: width, height: height)
            encoder.endEncoding()
        }

        // 1. Luma + dark channel.
        let pair = try session.texture(width: w, height: h, pixelFormat: .rg16Float, role: .presencePair)
        var isLinear: UInt32 = output.encoded ? 0 : 1
        var headroom = output.headroom
        try pass(gpu.lcPreparePSO, [input, pair], width: w, height: h) { e in
            e.setBytes(&isLinear, length: 4, index: 0)
            e.setBytes(&headroom, length: 4, index: 1)
        }

        // 2. Blur at a given sigma (in output pixels), downsampling first
        //    when the kernel would be too wide.
        func blurred(sigma: Float, role: ImageSession.TextureRole,
                     scratch: ImageSession.TextureRole) throws -> MTLTexture {
            var factor = 1
            while sigma / Float(factor) > 10, factor < 16 { factor *= 2 }
            var source = pair
            var bw = w, bh = h
            if factor > 1 {
                bw = max(1, w / factor); bh = max(1, h / factor)
                let small = try session.texture(width: bw, height: bh, pixelFormat: .rg16Float, role: scratch)
                var f = Int32(factor)
                try pass(gpu.lcDownsamplePSO, [pair, small], width: bw, height: bh) { e in
                    e.setBytes(&f, length: 4, index: 0)
                }
                source = small
            }
            var weights = Self.wideGaussianWeights(sigma: sigma / Float(factor))
            var taps = Int32(weights.count)
            let tmp = try session.texture(width: bw, height: bh, pixelFormat: .rg16Float, role: .presenceScratch)
            let out = try session.texture(width: bw, height: bh, pixelFormat: .rg16Float, role: role)
            try pass(gpu.lcBlurHPSO, [source, tmp], width: bw, height: bh) { e in
                e.setBytes(&weights, length: weights.count * 4, index: 0)
                e.setBytes(&taps, length: 4, index: 1)
            }
            try pass(gpu.lcBlurVPSO, [tmp, out], width: bw, height: bh) { e in
                e.setBytes(&weights, length: weights.count * 4, index: 0)
                e.setBytes(&taps, length: 4, index: 1)
            }
            return out
        }

        // Scales in sensor pixels, converted to this render's pixels.
        let small = try blurred(sigma: 1.0 / binSpan, role: .presenceSmall, scratch: .presenceDownA)
        let medium = try blurred(sigma: 4.0 / binSpan, role: .presenceMedium, scratch: .presenceDownB)
        let large = try blurred(sigma: 0.012 * shortSide / binSpan, role: .presenceLarge, scratch: .presenceDownC)

        // 3. Apply.
        let result = try session.texture(width: w, height: h, pixelFormat: .rgba16Float, role: outputRole)
        var texture = p.texture, clarity = p.clarity, dehaze = p.dehaze
        var purple = p.defringePurple, green = p.defringeGreen
        try pass(gpu.lcApplyPSO, [input, pair, small, medium, large, result], width: w, height: h) { e in
            e.setBytes(&texture, length: 4, index: 0)
            e.setBytes(&clarity, length: 4, index: 1)
            e.setBytes(&dehaze, length: 4, index: 2)
            e.setBytes(&purple, length: 4, index: 3)
            e.setBytes(&green, length: 4, index: 4)
            e.setBytes(&isLinear, length: 4, index: 5)
            e.setBytes(&headroom, length: 4, index: 6)
        }
        return result
    }

    // MARK: - Neural denoise

    private func applyAIDenoise(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                                input: MTLTexture, denoised: MTLTexture, strength: Float,
                                multipliers: SIMD4<Float>, renderInfo: RenderInfo,
                                outputRole: ImageSession.TextureRole) throws -> MTLTexture {
        let output = try session.texture(width: input.width, height: input.height,
                                         pixelFormat: .rgba16Float, role: outputRole)
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        encoder.setComputePipelineState(gpu.aiDenoiseBlendPSO)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(denoised, index: 1)
        encoder.setTexture(output, index: 2)
        var s = max(0, min(1, strength))
        let asShot = session.asShotMultipliers
        var ratio = SIMD4<Float>(multipliers.x / max(asShot.x, 1e-6), multipliers.y / max(asShot.y, 1e-6),
                                 multipliers.z / max(asShot.z, 1e-6), 1)
        var origin = SIMD2<UInt32>(UInt32(max(0, renderInfo.sensorRect.origin.x)),
                                   UInt32(max(0, renderInfo.sensorRect.origin.y)))
        var span = UInt32(renderInfo.isFullResolution ? 1 : renderInfo.binQuads * 2)
        encoder.setBytes(&s, length: 4, index: 0)
        encoder.setBytes(&ratio, length: 16, index: 1)
        encoder.setBytes(&origin, length: 8, index: 2)
        encoder.setBytes(&span, length: 4, index: 3)
        dispatch(encoder, pso: gpu.aiDenoiseBlendPSO, width: input.width, height: input.height)
        encoder.endEncoding()
        return output
    }

    // MARK: - Spot removal

    /// Two dispatches: rim statistics per patch, then the copy. The stats
    /// buffer is tiny (32 patches × 2 colours) and shared-storage, made
    /// fresh per render; Metal recycles it.
    private func applyHeal(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                           input: MTLTexture, patches: [HealPatch],
                           renderInfo: RenderInfo, binSpan: Float) throws -> MTLTexture {
        let output = try session.texture(width: input.width, height: input.height,
                                         pixelFormat: .rgba16Float, role: .healed)
        let count = min(patches.count, HealPatch.maximumCount)
        var gpuPatches = patches.prefix(count).map(HealPatchGPU.init)
        let statsLength = 2 * HealPatch.maximumCount * MemoryLayout<SIMD4<Float>>.size
        guard let stats = gpu.device.makeBuffer(length: statsLength, options: .storageModeShared),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        let summary = session.file.summary
        var sensorSize = SIMD2<Float>(Float(summary.rawWidth), Float(summary.rawHeight))
        var tileOrigin = SIMD2<Float>(Float(renderInfo.sensorRect.origin.x),
                                      Float(renderInfo.sensorRect.origin.y))
        var span = binSpan
        var patchCount = Int32(count)
        let patchBytes = count * MemoryLayout<HealPatchGPU>.stride

        encoder.setComputePipelineState(gpu.healStatsPSO)
        encoder.setTexture(input, index: 0)
        gpuPatches.withUnsafeMutableBytes { encoder.setBytes($0.baseAddress!, length: patchBytes, index: 0) }
        encoder.setBuffer(stats, offset: 0, index: 1)
        encoder.setBytes(&sensorSize, length: 8, index: 2)
        encoder.setBytes(&tileOrigin, length: 8, index: 3)
        encoder.setBytes(&span, length: 4, index: 4)
        encoder.dispatchThreadgroups(MTLSize(width: count, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))

        encoder.setComputePipelineState(gpu.healApplyPSO)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        gpuPatches.withUnsafeMutableBytes { encoder.setBytes($0.baseAddress!, length: patchBytes, index: 0) }
        encoder.setBuffer(stats, offset: 0, index: 1)
        encoder.setBytes(&patchCount, length: 4, index: 2)
        encoder.setBytes(&sensorSize, length: 8, index: 3)
        encoder.setBytes(&tileOrigin, length: 8, index: 4)
        encoder.setBytes(&span, length: 4, index: 5)
        dispatch(encoder, pso: gpu.healApplyPSO, width: input.width, height: input.height)
        encoder.endEncoding()
        return output
    }

    // MARK: - Detail stages

    private func applyDenoise(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                              input: MTLTexture, parameters: EditParameters,
                              binSpan: Float) throws -> MTLTexture {
        let output = try session.texture(width: input.width, height: input.height,
                                         pixelFormat: .rgba16Float, role: .denoised)
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        encoder.setComputePipelineState(gpu.denoisePSO)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        var luma = parameters.denoiseLuminance
        var chroma = parameters.denoiseColor
        // Binning averages 2N x 2N photosites, cutting noise by 2N.
        var noiseScale = 1 / binSpan
        encoder.setBytes(&luma, length: 4, index: 0)
        encoder.setBytes(&chroma, length: 4, index: 1)
        encoder.setBytes(&noiseScale, length: 4, index: 2)
        dispatch(encoder, pso: gpu.denoisePSO, width: input.width, height: input.height)
        encoder.endEncoding()
        return output
    }

    /// Gaussian taps for `sigma`, normalized. Capped at 33 taps (sigma
    /// up to ~5); beyond that the mask stops meaning "sharpening" anyway.
    static func gaussianWeights(sigma: Float) -> [Float] {
        let s = max(sigma, 0.3)
        let half = min(Int((3 * s).rounded(.up)), 16)
        var weights = (-half...half).map { exp(-Float($0 * $0) / (2 * s * s)) }
        let sum = weights.reduce(0, +)
        weights = weights.map { $0 / sum }
        return weights
    }

    private func applySharpen(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                              input: MTLTexture, outputRole: ImageSession.TextureRole,
                              parameters: EditParameters, output: RenderOutput,
                              binSpan: Float) throws -> MTLTexture {
        let w = input.width, h = input.height
        let blurA = try session.texture(width: w, height: h, pixelFormat: .r16Float, role: .blurA)
        let blurB = try session.texture(width: w, height: h, pixelFormat: .r16Float, role: .blurB)
        let result = try session.texture(width: w, height: h, pixelFormat: .rgba16Float, role: outputRole)

        var weights = Self.gaussianWeights(sigma: parameters.sharpenRadius / binSpan)
        var taps = Int32(weights.count)
        var isLinear: UInt32 = output.encoded ? 0 : 1
        var amount = parameters.sharpenAmount
        var threshold = parameters.sharpenThreshold

        func pass(_ pso: MTLComputePipelineState, _ textures: [MTLTexture],
                  _ bind: (MTLComputeCommandEncoder) -> Void) throws {
            guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
                throw RenderError.commandBufferFailed
            }
            encoder.setComputePipelineState(pso)
            for (i, t) in textures.enumerated() { encoder.setTexture(t, index: i) }
            bind(encoder)
            dispatch(encoder, pso: pso, width: w, height: h)
            encoder.endEncoding()
        }
        try pass(gpu.sharpenBlurHPSO, [input, blurA]) { e in
            e.setBytes(&weights, length: weights.count * 4, index: 0)
            e.setBytes(&taps, length: 4, index: 1)
            e.setBytes(&isLinear, length: 4, index: 2)
        }
        try pass(gpu.sharpenBlurVPSO, [blurA, blurB]) { e in
            e.setBytes(&weights, length: weights.count * 4, index: 0)
            e.setBytes(&taps, length: 4, index: 1)
        }
        try pass(gpu.sharpenApplyPSO, [input, blurB, result]) { e in
            e.setBytes(&amount, length: 4, index: 0)
            e.setBytes(&threshold, length: 4, index: 1)
            e.setBytes(&isLinear, length: 4, index: 2)
        }
        return result
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
                                    output: RenderOutput,
                                    renderInfo: RenderInfo, binSpan: Float) throws -> MTLTexture {
        let outputTexture = try session.texture(width: input.width, height: input.height,
                                                 pixelFormat: .rgba16Float, role: outputRole)
        // Brush masks are rasterized (if needed) before encoding begins.
        let locals = Array(parameters.locals.prefix(LocalAdjustment.maximumCount))
        let (maskTexture, slices) = session.brushMaskTexture(for: locals)

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

        // Grading. The LUT is 1 KB and the HSL table 96 bytes, both well
        // under setBytes' 4 KB limit, so no buffers to manage.
        var flags = SIMD3<UInt32>(parameters.toneCurve.isIdentity ? 0 : 1,
                                  parameters.hsl.isNeutral ? 0 : 1,
                                  parameters.splitToning.isNeutral ? 0 : 1)
        var lut = parameters.toneCurve.isIdentity ? Self.identityLUT : parameters.toneCurve.lookupTable()
        var hslTable = parameters.hsl.packed
        let st = parameters.splitToning
        var tint = SIMD4<Float>(st.shadowHue, st.shadowSaturation, st.highlightHue, st.highlightSaturation)
        var balance = st.balance
        encoder.setBytes(&flags, length: MemoryLayout<SIMD3<UInt32>>.size, index: 11)
        encoder.setBytes(&lut, length: lut.count * 4, index: 12)
        encoder.setBytes(&hslTable, length: hslTable.count * 4, index: 13)
        encoder.setBytes(&tint, length: 16, index: 14)
        encoder.setBytes(&balance, length: 4, index: 15)

        // Local adjustments.
        var packed = locals.map { LocalAdjustGPU($0, brushSlice: slices[$0.id] ?? -1) }
        if packed.isEmpty { packed = [LocalAdjustGPU(LocalAdjustment(name: "", shape: .whole), brushSlice: 0)] }
        var localCount = Int32(locals.count)
        var sensorSize = SIMD2<Float>(Float(session.file.summary.rawWidth),
                                      Float(session.file.summary.rawHeight))
        var tileOrigin = SIMD2<Float>(Float(renderInfo.sensorRect.origin.x),
                                      Float(renderInfo.sensorRect.origin.y))
        var span = binSpan
        var overlay = Int32(output.maskOverlay ?? -1)
        encoder.setBytes(&packed, length: packed.count * MemoryLayout<LocalAdjustGPU>.stride, index: 16)
        encoder.setBytes(&localCount, length: 4, index: 17)
        encoder.setBytes(&sensorSize, length: 8, index: 18)
        encoder.setBytes(&tileOrigin, length: 8, index: 19)
        encoder.setBytes(&span, length: 4, index: 20)
        encoder.setBytes(&overlay, length: 4, index: 21)
        encoder.setTexture(maskTexture, index: 2)

        var proofMode: UInt32 = output.proof == nil ? 0 : (output.gamutWarning ? 2 : 1)
        encoder.setBytes(&proofMode, length: 4, index: 22)
        var vibrance = parameters.vibrance
        encoder.setBytes(&vibrance, length: 4, index: 23)
        encoder.setTexture(proofTexture(for: output.proof), index: 3)

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
