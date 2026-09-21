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
            return "This camera’s sensor layout can’t be rendered: Latent renders only Bayer raws and linear DNGs"
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
    /// Highlights, Shadows, Whites and Blacks (not highlight recovery).
    public var toneRanges: ToneRanges = .neutral
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
    /// Per-channel curves, after `toneCurve`.
    public var channelCurves: RGBCurves = .identity
    public var hsl: HSLAdjustments
    public var splitToning: SplitToning
    /// Local adjustments, applied in order.
    public var locals: [LocalAdjustment]
    /// Crop and straighten. Not a pipeline stage: the presenter and the
    /// exporter sample through it (see `CropFrame`).
    public var crop: CropParameters
    /// Spot removal patches, applied in order in camera space.
    public var heals: [HealPatch]
    /// Red-eye corrections, applied in camera space after the patches.
    public var redEyes: [RedEyeSpot] = []
    /// Automatic sensor-dust patches (docs/Retouch.md §6), healed before
    /// the touch-up blemishes and `heals`.
    public var dust: [HealPatch] = []
    /// Touch-up: faces, sliders and the automatic blemishes (§7).
    public var touchUp: TouchUp = .neutral
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
                dust: [HealPatch] = [],
                touchUp: TouchUp = .neutral,
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
        self.dust = dust
        self.touchUp = touchUp
        self.texture = texture; self.clarity = clarity; self.dehaze = dehaze
        self.vibrance = vibrance
        self.defringePurple = defringePurple; self.defringeGreen = defringeGreen
        self.perspective = perspective
        self.aiDenoise = aiDenoise
    }

    /// Stage 5's list, in order: dust, then the active blemishes, then the
    /// user's patches, so a user patch over a dust spot reads the
    /// dust-healed image. Every heal site (the stage, the tile planning,
    /// the heal cache) reads this, never `heals` alone.
    public var allHealPatches: [HealPatch] { dust + touchUp.activeBlemishes + heals }

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
            && a.toneRanges == b.toneRanges && a.channelCurves == b.channelCurves
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
            && a.redEyes == b.redEyes
            && a.dust == b.dust && a.touchUp == b.touchUp
            && a.texture == b.texture && a.clarity == b.clarity && a.dehaze == b.dehaze
            && a.vibrance == b.vibrance
            && a.defringePurple == b.defringePurple && a.defringeGreen == b.defringeGreen
            && a.perspective == b.perspective && a.aiDenoise == b.aiDenoise
    }
}

/// Visualise Spots (docs/Retouch.md §6): the viewport's high-pass view
/// of the display texture that makes faint dust shadows stand out.
public struct SpotVisualisation: Sendable, Equatable {
    /// 0…1, the Contrast slider: how faint a dip still shows.
    public var threshold: Float
    /// The band's radius, so the high-pass is tuned to spots of that size.
    public var radiusSensorPx: Float

    public init(threshold: Float, radiusSensorPx: Float) {
        self.threshold = threshold
        self.radiusSensorPx = radiusSensorPx
    }
}

/// Mirror of `DustVisualiseParams` in Dust.metal.
struct DustVisualiseGPU {
    var threshold: Float
    var radiusSensorPx: Float
    var binSpan: Float
    var padding: Float = 0
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
    /// Visualise Spots, drawn over the viewport after sharpening. Never
    /// set for a file, like `maskOverlay`.
    public var spotVisualisation: SpotVisualisation? = nil
    /// Tint the touch-up skin mask red on the viewport (Show Skin Mask).
    public var touchUpOverlay = false

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
            && a.spotVisualisation == b.spotVisualisation && a.touchUpOverlay == b.touchUpOverlay
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
    /// such as grey-world white balance. For a linear source this is its
    /// pixels times the multipliers and `ImageSession.sourceGain`.
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
        // The Bayer order, or nil for a linear source; any other layout
        // can't be rendered.
        let bayerOrder: UInt8?
        switch summary.cfaPattern {
        case .bayer(let order): bayerOrder = order
        case .linearRGB: bayerOrder = nil
        default: throw RenderError.unsupportedCFAForV1
        }
        guard let cameraToWorking = session.cameraToWorkingMatrix else {
            throw RenderError.noCameraProfile(camera: summary.cameraModel)
        }

        let multipliers = session.multipliers(for: parameters.whiteBalance)
        let rawW = summary.rawWidth
        let rawH = summary.rawHeight
        let plan = Self.plan(rawWidth: rawW, rawHeight: rawH, scale: scale)

        // A region render with lens corrections must demosaic more than the
        // region. Distortion, TCA and keystone make each output pixel read
        // from somewhere else in the frame, up to tens of pixels away near
        // the edges, and anything read from outside the demosaiced texture
        // clamps to its edge row: a band of smeared streaks along the
        // region's border. So the stages up to and including the lens pass
        // run over `sourcePlan`, the region widened to every point the lens
        // pass reads (`lensSourceWindow`); the lens pass writes exactly the
        // requested region, and everything after it runs at that size.
        var sourcePlan = plan
        var widened = false
        if !cameraRGBOnly, case .fullResolution(let origin, let size) = plan,
           size.width < rawW || size.height < rawH,
           Self.wantsLensCorrection(session: session, parameters: parameters) {
            let window = Self.lensSourceWindow(
                for: CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height),
                sampling: LensSampling(session: session, parameters: parameters))
            sourcePlan = .fullResolution(origin: (Int(window.minX), Int(window.minY)),
                                         size: (Int(window.width), Int(window.height)))
            widened = true
        }

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
        let stageKey = Self.stageKey(plan: sourcePlan, source: summary.sourceKind, multipliers: multipliers,
                                     demosaic: parameters.demosaic)
        let cached = session.cachedCameraRGB(for: stageKey)

        // THE CAMERA-RGB SEAM. Whatever the source, what comes out of this
        // switch is the same thing: an rgba16Float texture of linear camera
        // RGB, black subtracted, scaled so the sensor's white is 1.0 and
        // multiplied by the white balance multipliers. A Bayer raw gets
        // there by demosaicing (or binning) its sensor plane; a linear
        // source is already demosaiced and only needs the multipliers, and
        // its BaselineExposure gain. Every stage after this point works on
        // that texture alone and never asks which kind of source made it.
        let cameraRGB: MTLTexture
        // What the camera-RGB texture covers: `sourcePlan`'s rectangle.
        let sourceInfo: RenderInfo
        let displayRole: ImageSession.TextureRole
        switch sourcePlan {
        case .fullResolution(let origin, let size):
            displayRole = .display
            if let bayerOrder {
                cameraRGB = try cached ?? renderFullResolution(
                    session: session, cmdBuffer: cmdBuffer, order: bayerOrder,
                    multipliers: multipliers, method: parameters.demosaic,
                    origin: origin, size: size)
            } else {
                cameraRGB = try cached ?? renderLinearUpload(
                    session: session, cmdBuffer: cmdBuffer, multipliers: multipliers,
                    origin: origin, size: size)
            }
            sourceInfo = RenderInfo(outputWidth: cameraRGB.width,
                                     outputHeight: cameraRGB.height,
                                     binQuads: 1, isFullResolution: true,
                                     // Nothing to demosaic in a linear source.
                                     demosaicUsed: bayerOrder == nil ? nil : parameters.demosaic,
                                     sensorRect: CGRect(x: origin.x, y: origin.y,
                                                        width: size.width, height: size.height),
                                     demosaicWasCached: cached != nil)
        case .binned(let quads):
            displayRole = .displayPreview
            if let bayerOrder {
                cameraRGB = try cached ?? renderBinned(
                    session: session, cmdBuffer: cmdBuffer, order: bayerOrder,
                    binQuads: quads, multipliers: multipliers)
            } else {
                cameraRGB = try cached ?? renderLinearBinned(
                    session: session, cmdBuffer: cmdBuffer, binQuads: quads, multipliers: multipliers)
            }
            let span = quads * 2
            sourceInfo = RenderInfo(outputWidth: cameraRGB.width,
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
            info?.pointee = sourceInfo
            return cameraRGB
        }

        // What this render returns: the requested region. The same as
        // `sourceInfo` unless the lens pass needed a wider source.
        var renderInfo = sourceInfo
        if widened, case .fullResolution(let origin, let size) = plan {
            renderInfo = RenderInfo(outputWidth: size.width, outputHeight: size.height, binQuads: 1,
                                    isFullResolution: true, demosaicUsed: sourceInfo.demosaicUsed,
                                    sensorRect: CGRect(x: origin.x, y: origin.y, width: size.width, height: size.height),
                                    demosaicWasCached: sourceInfo.demosaicWasCached)
        }

        // How many sensor pixels each output pixel spans, for scaling the
        // detail stages so the preview predicts the full-size result.
        let binSpan: Float = sourceInfo.isFullResolution ? 1 : Float(sourceInfo.binQuads * 2)

        var colourInput = cameraRGB

        // Stage 3: neural denoise. Blend the session's cached full-frame
        // result in, re-binned and re-white-balanced to match this render.
        // Never for a linear source (`ImageSession.supportsAIDenoise`): an
        // edit copied from a raw may carry a strength, but no result exists.
        if parameters.aiDenoise > 0, session.supportsAIDenoise, let denoised = session.aiDenoisedCameraRGB {
            colourInput = try applyAIDenoise(session: session, cmdBuffer: cmdBuffer, input: cameraRGB,
                                             denoised: denoised, strength: parameters.aiDenoise,
                                             multipliers: multipliers, renderInfo: sourceInfo,
                                             outputRole: displayRole == .display ? .aiDenoised : .aiDenoisedPreview)
        }

        // Stage 4: noise reduction, in camera space, before the matrix.
        if parameters.denoiseLuminance > 0 || parameters.denoiseColor > 0 {
            // colourInput, not cameraRGB: it may already carry the AI denoise blend.
            colourInput = try applyDenoise(session: session, cmdBuffer: cmdBuffer,
                                           input: colourInput, parameters: parameters,
                                           binSpan: binSpan)
        }

        // Stage 5: spot removal, in camera space, before the lens stage
        // moves pixels: the dust spots, then the touch-up blemishes, then
        // the user's patches (`allHealPatches`).
        let activeHeals = parameters.allHealPatches.filter {
            $0.targetBounds(sensorSize: CGSize(width: rawW, height: rawH)).intersects(sourceInfo.sensorRect)
        }
        // Stage 6: red eyes, on the same working texture.
        let activeRedEyes = parameters.redEyes.filter {
            !$0.isIdentity && $0.bounds(sensorSize: CGSize(width: rawW, height: rawH)).intersects(sourceInfo.sensorRect)
        }
        if !activeHeals.isEmpty || !activeRedEyes.isEmpty {
            colourInput = try applyHeal(session: session, cmdBuffer: cmdBuffer, input: colourInput,
                                        patches: activeHeals, redEyes: activeRedEyes, cameraToWorking: cameraToWorking,
                                        renderInfo: sourceInfo, binSpan: binSpan)
        }

        // Stage 7: lens corrections, still in camera space.
        if Self.wantsLensCorrection(session: session, parameters: parameters) {
            colourInput = try applyLensCorrection(session: session, cmdBuffer: cmdBuffer,
                                                  input: colourInput, parameters: parameters,
                                                  source: sourceInfo, output: renderInfo, binSpan: binSpan)
        }

        // Stages 8 to 15, in one kernel (Shaders/ColorPipeline.metal).
        var final = try applyColorAndTone(session: session, cmdBuffer: cmdBuffer,
                                          input: colourInput,
                                          outputRole: displayRole,
                                          cameraToWorking: cameraToWorking,
                                          multipliers: multipliers,
                                          parameters: parameters,
                                          output: output,
                                          renderInfo: renderInfo, binSpan: binSpan)

        // Stage 16: touch-up (skin, teeth, eyes), display-referred, on the
        // faces' region masks. Only with masks to work on: the session
        // holds them once MLKit has built them (docs/Retouch.md §7), and a
        // render without them (a thumbnail, the CLI) skips the stage.
        if parameters.touchUp.wantsMasks,
           let masks = session.touchUpMaskTexture(enabled: parameters.touchUp.enabledFaceIDs) {
            final = try applyTouchUp(session: session, cmdBuffer: cmdBuffer, input: final, masks: masks,
                                     preview: displayRole != .display, parameters: parameters,
                                     output: output, renderInfo: renderInfo, binSpan: binSpan)
        }

        // Stage 17: presence (texture, clarity, dehaze, defringe),
        // display-referred, before sharpening so the sharpener sees the
        // final tonality.
        if parameters.wantsLocalContrast {
            final = try applyLocalContrast(session: session, cmdBuffer: cmdBuffer, input: final,
                                           outputRole: displayRole == .display ? .presence : .presencePreview,
                                           parameters: parameters, output: output,
                                           renderInfo: renderInfo, binSpan: binSpan)
        }

        // Stage 18: sharpening, on the display-referred result.
        if parameters.sharpenAmount > 0 {
            final = try applySharpen(session: session, cmdBuffer: cmdBuffer, input: final,
                                     outputRole: displayRole == .display ? .sharpened : .sharpenedPreview,
                                     parameters: parameters, output: output, binSpan: binSpan)
        }

        // Display pass: Visualise Spots, for the viewport only (a file
        // never asks for it), after every stage so it shows the picture
        // as it is on screen.
        if let visualisation = output.spotVisualisation {
            final = try applyDustVisualise(session: session, cmdBuffer: cmdBuffer, input: final,
                                           outputRole: displayRole == .display ? .visualised : .visualisedPreview,
                                           visualisation: visualisation, binSpan: binSpan)
        }

        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        if cmdBuffer.status == .error { throw RenderError.commandBufferFailed }

        info?.pointee = renderInfo
        return final
    }

    private static let identityLUT: [Float] = ToneCurve.identity.lookupTable()

    /// Buffers 24 to 26 of the colour kernel. Both tables are small enough
    /// for setBytes (1 KB and 3 KB); a neutral module binds a single zero
    /// and its flag keeps the kernel from reading further.
    private func encodeToneRangesAndChannelCurves(_ encoder: MTLComputeCommandEncoder,
                                                  parameters: EditParameters) {
        var toneRangesOn: UInt32 = parameters.toneRanges.isNeutral ? 0 : 1
        var toneRangeLUT = toneRangesOn == 0 ? [Float(0)] : parameters.toneRanges.lookupTable()
        var channelLUT = parameters.channelCurves.isIdentity ? [Float(0)] : parameters.channelCurves.lookupTable()
        encoder.setBytes(&toneRangeLUT, length: toneRangeLUT.count * 4, index: 24)
        encoder.setBytes(&channelLUT, length: channelLUT.count * 4, index: 25)
        encoder.setBytes(&toneRangesOn, length: 4, index: 26)
    }

    // MARK: - Lens corrections

    static func wantsLensCorrection(session: ImageSession, parameters p: EditParameters) -> Bool {
        if p.manualDistortion != 0 || p.manualVignetting != 0 || !p.perspective.isIdentity { return true }
        guard let c = session.lensCorrection else { return false }
        return (p.lensDistortion && c.distortion != nil)
            || (p.lensTCA && c.tca != nil)
            || (p.lensVignetting && c.vignetting != nil)
    }

    /// Everything the lens pass needs to know to map an output pixel to
    /// the place it reads from, resolved from the session's profile and
    /// the edit's switches. The GPU kernel (LensCorrect.metal) and
    /// `sourcePoints` below do the same arithmetic with these values.
    struct LensSampling {
        var sensorSize: SIMD2<Float>
        var cropRatio: Float
        var autoScale: Float
        var distortion: DistortionModel?
        var manualDistortion: Float
        var tca: TCAModel?
        var vignetting: VignettingModel?
        var manualVignetting: Float
        var perspectiveInverse: simd_float3x3

        init(sensorSize: SIMD2<Float>, cropRatio: Float = 1, autoScale: Float = 1,
             distortion: DistortionModel? = nil, manualDistortion: Float = 0, tca: TCAModel? = nil,
             vignetting: VignettingModel? = nil, manualVignetting: Float = 0,
             perspectiveInverse: simd_float3x3 = matrix_identity_float3x3) {
            self.sensorSize = sensorSize
            self.cropRatio = cropRatio
            self.autoScale = autoScale
            self.distortion = distortion
            self.manualDistortion = manualDistortion
            self.tca = tca
            self.vignetting = vignetting
            self.manualVignetting = manualVignetting
            self.perspectiveInverse = perspectiveInverse
        }

        init(session: ImageSession, parameters p: EditParameters) {
            let c = session.lensCorrection
            let summary = session.file.summary
            sensorSize = SIMD2(Float(summary.rawWidth), Float(summary.rawHeight))
            cropRatio = c?.cropRatio ?? 1
            distortion = p.lensDistortion ? c?.distortion : nil
            autoScale = distortion != nil ? (c?.autoScale ?? 1) : 1
            manualDistortion = p.manualDistortion
            tca = p.lensTCA ? c?.tca : nil
            vignetting = p.lensVignetting ? c?.vignetting : nil
            manualVignetting = p.manualVignetting
            perspectiveInverse = p.perspective.inverseMatrix
        }

        /// Where the corrected image's sensor point `sensor` reads from in
        /// the uncorrected one: green, red and blue (TCA pulls red and blue
        /// to slightly different radii). A Swift twin of the kernel.
        func sourcePoints(forSensorPoint sensor: SIMD2<Float>) -> [SIMD2<Float>] {
            let halfShort = min(sensorSize.x, sensorSize.y) * 0.5
            var cu = (sensor - sensorSize * 0.5) * autoScale
            let q = perspectiveInverse * SIMD3(cu / halfShort, 1)
            cu = SIMD2(q.x, q.y) / max(q.z, 1e-4) * halfShort
            let ru = simd_length(cu) / halfShort * cropRatio
            var f = distortion?.factor(atUndistortedRadius: ru) ?? 1
            if manualDistortion != 0 { f *= 1 - manualDistortion + manualDistortion * ru * ru }
            let cd = cu * f
            let centre = sensorSize * 0.5
            guard let tca else { return [cd + centre] }
            let rd = simd_length(cd) / halfShort * cropRatio
            let fr = tca.red.x * rd * rd + tca.red.y * rd + tca.red.z
            let fb = tca.blue.x * rd * rd + tca.blue.y * rd + tca.blue.z
            return [cd + centre, cd * fr + centre, cd * fb + centre]
        }
    }

    /// Sensor pixels of apron kept around the lens pass's reads: one for
    /// the bilinear sample, the rest so the region demosaic's own edge
    /// (where RCD mirrors instead of reading real neighbours, up to 11
    /// pixels in) stays outside everything the lens pass reads.
    static let lensApron: CGFloat = 16

    /// The sensor rectangle a full-resolution render of `region` must
    /// demosaic for the lens pass to read only real pixels: the bounds of
    /// every point it samples, plus `lensApron`, clamped to the sensor and
    /// with an even origin (the Bayer parity rule in `plan`).
    ///
    /// The reads are measured on a grid over the region, not just its
    /// corners: with barrel distortion the edge midpoints move furthest,
    /// and a moustache profile can peak anywhere. The map is smooth, so a
    /// grid of at most 64 steps a side is within a fraction of a pixel of
    /// the true bounds; the apron absorbs the rest.
    static func lensSourceWindow(for region: CGRect, sampling: LensSampling) -> CGRect {
        var lo = SIMD2<Float>(Float(region.minX), Float(region.minY))
        var hi = SIMD2<Float>(Float(region.maxX), Float(region.maxY))
        let columns = max(2, min(64, Int(region.width / 16) + 1))
        let rows = max(2, min(64, Int(region.height / 16) + 1))
        for j in 0...rows {
            for i in 0...columns {
                // Pixel centres from the first to the last, as the kernel reads.
                let x = Float(region.minX) + 0.5 + Float(i) / Float(columns) * Float(region.width - 1)
                let y = Float(region.minY) + 0.5 + Float(j) / Float(rows) * Float(region.height - 1)
                for p in sampling.sourcePoints(forSensorPoint: SIMD2(x, y)) {
                    lo = simd_min(lo, p)
                    hi = simd_max(hi, p)
                }
            }
        }
        let sensor = CGRect(x: 0, y: 0, width: CGFloat(sampling.sensorSize.x), height: CGFloat(sampling.sensorSize.y))
        let reads = CGRect(x: CGFloat(lo.x), y: CGFloat(lo.y),
                           width: CGFloat(hi.x - lo.x), height: CGFloat(hi.y - lo.y))
            .insetBy(dx: -lensApron, dy: -lensApron)
            .intersection(sensor)
        // Whole pixels, the origin snapped down to even, never smaller than
        // the region itself.
        let minX = (Int(reads.minX.rounded(.down)) & ~1), minY = (Int(reads.minY.rounded(.down)) & ~1)
        let maxX = min(Int(reads.maxX.rounded(.up)), Int(sensor.width))
        let maxY = min(Int(reads.maxY.rounded(.up)), Int(sensor.height))
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).union(region)
    }

    /// Where the corrected image's sensor point `p` (the output grid: what
    /// a render of the whole frame shows at that pixel) reads from in the
    /// uncorrected one: the green channel of `LensSampling.sourcePoints`.
    /// The point itself when no lens correction is wanted. A face box found
    /// on a render goes through here to the raw grid the sidecar stores
    /// (docs/Retouch.md §7), so lens and keystone edits never move it.
    public func rawSensorPoint(forOutputPoint p: SIMD2<Float>, session: ImageSession,
                               parameters: EditParameters) -> SIMD2<Float> {
        guard Self.wantsLensCorrection(session: session, parameters: parameters) else { return p }
        return LensSampling(session: session, parameters: parameters).sourcePoints(forSensorPoint: p)[0]
    }

    /// The inverse: where the raw-grid point `p` lands on the corrected
    /// image. `sourcePoints` has no closed inverse (a polynomial in the
    /// radius, then keystone), so this is Newton's method from `p` itself
    /// with a central-difference Jacobian. A profile moves a pixel by a
    /// few tens of pixels and three steps land within 0.05 px; a strong
    /// keystone moves the corners by thousands and needs a few more, so
    /// it runs until the residual is under a thousandth of a pixel, at
    /// most eight steps (each five `sourcePoints`). Identity without lens
    /// correction. Where the map folds (a manual distortion strong enough
    /// that the radius stops growing before the corner) there is no
    /// inverse and the last iterate is returned. SensorPointTests.
    public func outputSensorPoint(forRawPoint p: SIMD2<Float>, session: ImageSession,
                                  parameters: EditParameters) -> SIMD2<Float> {
        guard Self.wantsLensCorrection(session: session, parameters: parameters) else { return p }
        let sampling = LensSampling(session: session, parameters: parameters)
        func raw(_ q: SIMD2<Float>) -> SIMD2<Float> { sampling.sourcePoints(forSensorPoint: q)[0] }
        let h: Float = 0.5
        var q = p
        for _ in 0..<8 {
            let residual = raw(q) - p
            guard simd_length(residual) > 1e-3 else { break }
            let dx = (raw(q + SIMD2(h, 0)) - raw(q - SIMD2(h, 0))) / (2 * h)
            let dy = (raw(q + SIMD2(0, h)) - raw(q - SIMD2(0, h))) / (2 * h)
            let jacobian = simd_float2x2(columns: (dx, dy))
            guard abs(jacobian.determinant) > 1e-8 else { break }
            q -= jacobian.inverse * residual
        }
        return q
    }

    /// The lens pass. Reads `input`, which covers `source.sensorRect`, and
    /// writes a texture covering `output.sensorRect`; the two are the same
    /// rectangle except for a widened region render (`lensSourceWindow`).
    private func applyLensCorrection(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                                     input: MTLTexture, parameters p: EditParameters,
                                     source: RenderInfo, output info: RenderInfo,
                                     binSpan: Float) throws -> MTLTexture {
        let outputWidth = info.isFullResolution ? info.outputWidth : input.width
        let outputHeight = info.isFullResolution ? info.outputHeight : input.height
        let output = try session.texture(width: outputWidth, height: outputHeight,
                                         pixelFormat: .rgba16Float, role: .lensCorrected)
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        let sampling = LensSampling(session: session, parameters: p)

        var sensorSize = sampling.sensorSize
        var tileOrigin = SIMD2<Float>(Float(info.sensorRect.origin.x), Float(info.sensorRect.origin.y))
        var sourceOrigin = SIMD2<Float>(Float(source.sensorRect.origin.x), Float(source.sensorRect.origin.y))
        var span = binSpan
        var cropRatio = sampling.cropRatio
        var autoScale = sampling.autoScale
        var distType: Int32 = 0
        var distTerms = SIMD3<Float>(0, 0, 0)
        if let d = sampling.distortion {
            (distType, distTerms) = d.packed
        }
        var manualDist = sampling.manualDistortion
        var tcaOn: Int32 = sampling.tca != nil ? 1 : 0
        var tcaRed = sampling.tca?.red ?? SIMD3(0, 0, 1)
        var tcaBlue = sampling.tca?.blue ?? SIMD3(0, 0, 1)
        var vigOn: Int32 = sampling.vignetting != nil ? 1 : 0
        var vig = sampling.vignetting.map { SIMD3<Float>($0.k1, $0.k2, $0.k3) } ?? SIMD3(0, 0, 0)
        var manualVig = sampling.manualVignetting

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
        var perspective = sampling.perspectiveInverse
        encoder.setBytes(&perspective, length: MemoryLayout<simd_float3x3>.size, index: 14)
        encoder.setBytes(&sourceOrigin, length: 8, index: 15)
        dispatch(encoder, pso: gpu.lensCorrectPSO, width: outputWidth, height: outputHeight)
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

    // MARK: - Touch-up

    /// The touch-up stage (TouchUpStage.swift, Shaders/TouchUp.metal) on
    /// the display-referred image, over the session's region masks.
    private func applyTouchUp(session: ImageSession, cmdBuffer: MTLCommandBuffer, input: MTLTexture,
                              masks: MTLTexture, preview: Bool, parameters p: EditParameters,
                              output: RenderOutput, renderInfo: RenderInfo, binSpan: Float) throws -> MTLTexture {
        let result = try session.texture(width: input.width, height: input.height, pixelFormat: .rgba16Float,
                                         role: preview ? .touchUpPreview : .touchUp)
        let summary = session.file.summary
        let sensorSize = SIMD2<Float>(Float(summary.rawWidth), Float(summary.rawHeight))
        // The blur scales are sensor pixels, converted to this render's.
        let faceWidth = p.touchUp.medianFaceWidthPixels(sensorSize: sensorSize)
        let params = TouchUpStage.Params(
            skin: p.touchUp.skinSmoothing / 100, teeth: p.touchUp.teethWhitening / 100, eyes: p.touchUp.eyes / 100,
            sigmaFine: 1.5 / binSpan, sigmaMid: TouchUp.sigmaMid(faceWidth: faceWidth) / binSpan,
            isLinear: !output.encoded, headroom: output.headroom,
            tileOrigin: SIMD2(Float(renderInfo.sensorRect.origin.x), Float(renderInfo.sensorRect.origin.y)),
            binSpan: binSpan, sensorSize: sensorSize, overlay: output.touchUpOverlay)
        try TouchUpStage.encode(input: input, output: result, masks: masks, params: params,
                                session: session, preview: preview, gpu: gpu, commandBuffer: cmdBuffer)
        return result
    }

    // MARK: - Visualise Spots

    /// The high-pass view of the display texture (Shaders/Dust.metal,
    /// `dustVisualise`), tuned to the spot radius the panel is looking for.
    private func applyDustVisualise(session: ImageSession, cmdBuffer: MTLCommandBuffer, input: MTLTexture,
                                    outputRole: ImageSession.TextureRole, visualisation: SpotVisualisation,
                                    binSpan: Float) throws -> MTLTexture {
        let pso = try gpu.lazyPipeline(.dustVisualise)
        let result = try session.texture(width: input.width, height: input.height,
                                         pixelFormat: .rgba16Float, role: outputRole)
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        var params = DustVisualiseGPU(threshold: visualisation.threshold,
                                      radiusSensorPx: visualisation.radiusSensorPx, binSpan: binSpan)
        encoder.setComputePipelineState(pso)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(result, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<DustVisualiseGPU>.stride, index: 0)
        dispatch(encoder, pso: pso, width: input.width, height: input.height)
        encoder.endEncoding()
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

    /// Patches in order, each over its own bounding box (HealStage).
    private func applyHeal(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                           input: MTLTexture, patches: [HealPatch],
                           redEyes: [RedEyeSpot], cameraToWorking: simd_float3x3,
                           renderInfo: RenderInfo, binSpan: Float) throws -> MTLTexture {
        let output = try session.texture(width: input.width, height: input.height,
                                         pixelFormat: .rgba16Float, role: .healed)
        let summary = session.file.summary
        try HealStage.encode(patches: patches, redEyes: redEyes, cameraToWorking: cameraToWorking,
                             input: input, output: output,
                             sensorSize: SIMD2(Float(summary.rawWidth), Float(summary.rawHeight)),
                             tileOrigin: SIMD2(Float(renderInfo.sensorRect.origin.x),
                                               Float(renderInfo.sensorRect.origin.y)),
                             binSpan: binSpan, gpu: gpu, commandBuffer: cmdBuffer)
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

    static func stageKey(plan: RenderPlan, source: RawSourceKind, multipliers: SIMD4<Float>,
                         demosaic: DemosaicMethod) -> ImageSession.StageKey {
        // A linear source is never demosaiced, so the method can't change
        // its pixels; normalized, like binning below, so a method change
        // doesn't needlessly miss the cache.
        let method = source == .linearRGB ? .bilinear : demosaic
        switch plan {
        case .fullResolution(let origin, let size):
            return .init(source: source, isFullResolution: true, originX: origin.x, originY: origin.y,
                         width: size.width, height: size.height, quads: 0,
                         multipliers: multipliers, demosaic: method)
        case .binned(let quads):
            // Demosaic method is irrelevant to binning; normalize it so a
            // method change doesn't needlessly miss the cache.
            return .init(source: source, isFullResolution: false, originX: 0, originY: 0,
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
        // A linear source scales them by its own clip level and gain
        // (`ImageSession.highlightClipLevel`); for a Bayer raw that factor
        // is 1 and this is the multipliers themselves.
        var clipLevel = session.highlightClipLevel(multipliers: multipliers)
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
        // The curve flag is a bit mask: 1 master curve, 2 channel curves.
        var flags = SIMD3<UInt32>((parameters.toneCurve.isIdentity ? 0 : 1) | (parameters.channelCurves.isIdentity ? 0 : 2),
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
        encodeToneRangesAndChannelCurves(encoder, parameters: parameters)
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

    /// Stage 1: black/white levels and white balance, producing the
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
        try encodeBilinear(cmdBuffer: cmdBuffer, cfa: cfa, order: order,
                           output: try session.texture(width: cfa.width, height: cfa.height,
                                                       pixelFormat: .rgba16Float, role: .cameraRGB))
    }

    /// The bilinear demosaic of any CFA texture into `output`.
    func encodeBilinear(cmdBuffer: MTLCommandBuffer, cfa: MTLTexture, order: UInt8,
                        output rgbTex: MTLTexture) throws -> MTLTexture {
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
        try encodeRCD(cmdBuffer: cmdBuffer, cfa: cfa, order: order) { format, role in
            try session.texture(width: cfa.width, height: cfa.height, pixelFormat: format, role: role)
        }
    }

    /// The RCD passes on any CFA texture, with the textures they write
    /// handed out by `texture` (the session's pool, or a test's own).
    func encodeRCD(cmdBuffer: MTLCommandBuffer, cfa: MTLTexture, order: UInt8,
                   texture: (MTLPixelFormat, ImageSession.TextureRole) throws -> MTLTexture) throws -> MTLTexture {
        let w = cfa.width, h = cfa.height

        let vhDir = try texture(.r16Float, .rcdVHDir)
        let lowPass = try texture(.r32Float, .rcdLowPass)
        let diagonal = try texture(.rg32Float, .rcdDiagonal)
        let pqDir = try texture(.r16Float, .rcdPQDir)
        let rgbA = try texture(.rgba16Float, .cameraRGB)
        let rgbB = try texture(.rgba16Float, .rcdScratch)

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

    // MARK: - Linear sources

    /// The multipliers a linear source's kernels apply: the white balance,
    /// times the session's BaselineExposure gain. One factor per channel,
    /// so a kernel multiplies once.
    private static func linearMultipliers(_ multipliers: SIMD4<Float>, session: ImageSession) -> SIMD4<Float> {
        multipliers * session.sourceGain
    }

    /// Full resolution for a linear source: the plane's pixels in the
    /// requested rectangle, times the multipliers. What `renderFullResolution`
    /// produces for a Bayer raw, without the demosaic (see LinearSource.metal).
    private func renderLinearUpload(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                                    multipliers: SIMD4<Float>,
                                    origin: (x: Int, y: Int),
                                    size: (width: Int, height: Int)) throws -> MTLTexture {
        let pso = try gpu.lazyPipeline(.linearUpload)
        let rgbTex = try session.texture(width: size.width, height: size.height,
                                         pixelFormat: .rgba16Float, role: .cameraRGB)
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        encoder.setComputePipelineState(pso)
        encoder.setBuffer(session.sensorBuffer, offset: 0, index: 0)
        var planeWidth = UInt32(session.file.summary.rawWidth)
        var mul = Self.linearMultipliers(multipliers, session: session)
        var originXY = SIMD2<UInt32>(UInt32(origin.x), UInt32(origin.y))
        encoder.setBytes(&planeWidth, length: 4, index: 1)
        encoder.setBytes(&mul, length: 16, index: 2)
        encoder.setBytes(&originXY, length: 8, index: 3)
        encoder.setTexture(rgbTex, index: 0)
        dispatch(encoder, pso: pso, width: size.width, height: size.height)
        encoder.endEncoding()
        return rgbTex
    }

    /// Reduced resolution for a linear source: a box average over the same
    /// `2 x binQuads` span, and so the same output size and sensor
    /// coverage, as the Bayer `renderBinned`.
    private func renderLinearBinned(session: ImageSession, cmdBuffer: MTLCommandBuffer,
                                    binQuads: Int, multipliers: SIMD4<Float>) throws -> MTLTexture {
        let pso = try gpu.lazyPipeline(.linearBinned)
        let summary = session.file.summary
        let span = binQuads * 2
        let outW = max(1, summary.rawWidth / span)
        let outH = max(1, summary.rawHeight / span)
        let rgbTex = try session.texture(width: outW, height: outH,
                                         pixelFormat: .rgba16Float, role: .cameraRGB)
        guard let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw RenderError.commandBufferFailed
        }
        encoder.setComputePipelineState(pso)
        encoder.setBuffer(session.sensorBuffer, offset: 0, index: 0)
        var planeWidth = UInt32(summary.rawWidth)
        var planeHeight = UInt32(summary.rawHeight)
        var mul = Self.linearMultipliers(multipliers, session: session)
        var spanValue = UInt32(span)
        encoder.setBytes(&planeWidth, length: 4, index: 1)
        encoder.setBytes(&planeHeight, length: 4, index: 2)
        encoder.setBytes(&mul, length: 16, index: 3)
        encoder.setBytes(&spanValue, length: 4, index: 4)
        encoder.setTexture(rgbTex, index: 0)
        dispatch(encoder, pso: pso, width: outW, height: outH)
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
