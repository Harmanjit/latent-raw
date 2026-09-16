import Foundation
import Metal
import simd
import RawCore
import ColorKit
import LensKit

/// One image, loaded and ready to render repeatedly.
///
/// Interactive editing renders the *same* image over and over — every
/// slider drag, every zoom, every panel toggle. Anything that depends only
/// on the file, not on the edit parameters, is paid for once here and then
/// reused.
///
/// Lifetime: create one when the user opens an image, release it when they
/// move on. Each holds its sensor buffer plus pooled textures, so the app
/// should keep a small bounded number. A full-resolution RCD render is the
/// heaviest case by far — see `TextureRole` for why.
public final class ImageSession {
    public let file: RawFile
    let gpu: GPUContext

    /// The source pixels, uploaded once (DESIGN.md §7.2: shared storage,
    /// because the CPU writes it and the GPU reads it): the sensor plane
    /// for a Bayer raw, the `LinearPlane` for a linear source.
    let sensorBuffer: MTLBuffer

    /// Which kind of image this is, and so which kernels start its renders.
    public var sourceKind: RawSourceKind { file.summary.sourceKind }

    /// A factor every pixel is multiplied by at the camera-RGB seam, on
    /// top of the white balance. For a linear source it is
    /// 2^BaselineExposure: a merge stores its pixels relative to its
    /// brightest frame and records in BaselineExposure how much to brighten
    /// them, so applying it here makes Exposure 0 look like the reference
    /// frame, as Adobe Camera Raw shows the same file. Always 1 for a Bayer
    /// raw, whose BaselineExposure (DNGs from cameras have one) the
    /// pipeline has never applied; starting now would move every existing
    /// edit.
    public let sourceGain: Float

    /// Where highlight reconstruction treats a channel as clipped, as a
    /// factor of that channel's white balance multiplier, in the seam's
    /// units. For a Bayer raw the sensor clips at 1.0 before white balance,
    /// so this is 1. A merge's pixels can go far above 1.0 (the darker
    /// frames' highlights) and it records its own clip level; that level
    /// is in stored values, before `sourceGain`, so the gain scales it too.
    public let highlightClipScale: Float

    /// True when lens correction profiles are never looked up for this
    /// image, because the file says its pixels are already corrected
    /// (a panorama). Its EXIF may still name the lens, copied from the
    /// source frames; matching on that would correct the lens twice.
    /// Manual lens sliders still apply.
    public let lensCorrectionAlreadyApplied: Bool

    /// Whether the neural denoiser can run on this image. Not for linear
    /// sources: the network only accepts values up to white and fades
    /// back to the noisy original near it (`AIDenoiser`), which on a
    /// merge's values far above 1.0 would do nothing useful over most of
    /// the highlights and leave a visible boundary where the fade ends.
    public var supportsAIDenoise: Bool { sourceKind == .bayer }

    /// The camera's as-shot multipliers, normalized against green.
    public let asShotMultipliers: SIMD4<Float>

    /// The camera's colour characterization. nil when LibRaw has no profile
    /// for this camera, or its matrix is singular.
    public let profile: ColorKit.CameraColorProfile?

    /// The as-shot white balance as temperature and tint, so the UI can
    /// show where the camera set it. Derived by searching the Planckian
    /// locus, so it's approximate — rendering with `WhiteBalance.asShot`
    /// uses the exact multipliers instead of routing through this.
    public let asShotWhiteBalance: ColorKit.WhiteBalance

    /// Camera RGB -> linear Rec.2020.
    public var cameraToWorkingMatrix: simd_float3x3? { profile?.cameraToWorking }

    /// The lens profile for this shot, resolved at its focal length and
    /// aperture (DESIGN.md §9.2). nil when the database has nothing for
    /// this camera and lens; manual corrections still work then.
    public let lensCorrection: LensCorrection?

    /// What a pooled texture is for.
    ///
    /// Role is part of the pool key because several stages want textures of
    /// identical size and format but must not share storage — a kernel that
    /// reads its input while writing its output would corrupt the image as
    /// threads raced each other.
    ///
    /// The RCD roles are the memory-hungry ones: a full-resolution 24MP RCD
    /// render holds the CFA plane, four intermediate statistic textures and
    /// two RGB buffers simultaneously, on the order of 700MB. That's the
    /// price of full-image passes instead of RawTherapee's 194x194 tiling,
    /// and it's acceptable only because RCD runs for export and 100% zoom,
    /// never for interactive fit-to-window rendering. If this ever needs to
    /// shrink, tiling with threadgroup memory is the answer.
    enum TextureRole: Hashable {
        case cfa            // single-channel, post-white-balance CFA data
        case cameraRGB      // demosaiced, still in camera colour space
        case display        // after colour and tone, ready for screen or export
        case displayPreview // same, but for the binned whole-image preview —
                            // a separate role so a tile of the same size can
                            // never overwrite the preview it's drawn over
        case rcdVHDir       // vertical/horizontal directional discrimination
        case rcdLowPass     // local average for ratio correction
        case rcdDiagonal    // packed P/Q diagonal high-pass statistics
        case rcdPQDir       // diagonal directional discrimination
        case rcdScratch     // ping-pong partner for the RGB passes
        case denoised       // camera RGB after noise reduction
        case healed         // camera RGB after spot removal
        case lensCorrected  // camera RGB after lens corrections
        case blurA          // sharpening: horizontal blur of luminance
        case blurB          // sharpening: full blur of luminance
        case sharpened      // final output when sharpening ran (tile)
        case sharpenedPreview
        case presencePair, presenceScratch, presenceSmall, presenceMedium, presenceLarge
        case presenceDownA, presenceDownB, presenceDownC
        case presence, presencePreview   // output of the presence stage
        case aiDenoised, aiDenoisedPreview // camera RGB after the neural denoiser is blended in
    }

    /// Which set of pooled textures a render draws from. Pools never share
    /// storage, so a render in one can't overwrite a texture another shows
    /// or holds, whatever their sizes, and each can be released on its own.
    public enum TexturePool: Hashable, Sendable {
        /// The editor's preview, tile and scopes; exports and thumbnails.
        case view
        /// The magnifier's tile, whose size follows the loupe's keystone
        /// and heal reach as the pointer moves.
        case magnifier
        /// One-off renders read back for analysis (red-eye detection, model
        /// input), which must leave the textures on screen alone.
        case analysis
    }

    private struct TextureKey: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: UInt
        let role: TextureRole
        let pool: TexturePool
    }

    private var texturePool: [TextureKey: MTLTexture] = [:]
    /// The pool `texture(width:height:pixelFormat:role:)` hands out from;
    /// set around a render by `withTexturePool`.
    private var currentPool = TexturePool.view

    /// Rasterized brush masks, created on first use.
    private var brushMasks: BrushMaskSet?
    /// A 1x1 array texture to bind when there are no brush masks: Metal
    /// requires every declared texture slot to be bound.
    private var placeholderMasks: MTLTexture?

    /// Pixels for AI-generated masks, keyed by local id. Set by the app
    /// after MLKit produces them; the session only stores and uploads.
    private var aiMasks: [UUID: MaskBitmap] = [:]

    /// The neural denoiser's output for the whole frame: camera RGB at
    /// as-shot white balance, full resolution. Produced on demand by
    /// MLKit (about 12 s for 24 MP) and kept for the life of the session
    /// unless critical memory pressure takes it (`releaseMemory(for:)`);
    /// the pipeline blends it in per render. `aiDenoiseModel` names what
    /// produced it, so a different model invalidates it.
    public private(set) var aiDenoisedCameraRGB: MTLTexture?
    public private(set) var aiDenoiseModel: String?

    public func setAIDenoised(_ texture: MTLTexture?, model: String?) {
        aiDenoisedCameraRGB = texture
        aiDenoiseModel = texture == nil ? nil : model
    }

    public func setAIMask(_ bitmap: MaskBitmap?, forLocal id: UUID) {
        aiMasks[id] = bitmap
    }

    public func hasAIMask(forLocal id: UUID) -> Bool { aiMasks[id] != nil }

    /// Keeps brush and AI mask slices in step with `locals`; returns the
    /// texture to bind and each such local's slice.
    func brushMaskTexture(for locals: [LocalAdjustment]) -> (MTLTexture?, [UUID: Int32]) {
        let needsSlices = locals.contains { $0.shape.usesMaskSlice }
        if needsSlices {
            if brushMasks == nil {
                brushMasks = BrushMaskSet(device: gpu.device, sensorWidth: file.summary.rawWidth,
                                          sensorHeight: file.summary.rawHeight)
            }
            guard let set = brushMasks else { return (nil, [:]) }
            return (set.texture, set.sync(locals: locals, aiMasks: aiMasks))
        }
        if placeholderMasks == nil {
            let d = MTLTextureDescriptor()
            d.textureType = .type2DArray
            d.pixelFormat = .r8Unorm
            d.width = 1; d.height = 1; d.arrayLength = 1
            d.storageMode = .shared
            d.usage = [.shaderRead]
            placeholderMasks = gpu.device.makeTexture(descriptor: d)
        }
        return (placeholderMasks, [:])
    }

    /// Everything the demosaiced camera-RGB stage depends on. Two renders
    /// with equal keys produce identical camera-RGB textures, so the second
    /// can skip demosaicing entirely (DESIGN.md §8.2, "stage cache").
    ///
    /// What's deliberately *not* in here: exposure, contrast, grey point,
    /// highlight settings, output space — those all act after this stage.
    ///
    /// The source kind is: a session holds one kind, but keys are compared
    /// as plain values, and a Bayer render and a linear render of the same
    /// shape mean different pixels.
    struct StageKey: Hashable {
        let source: RawSourceKind
        let isFullResolution: Bool
        let originX: Int, originY: Int
        let width: Int, height: Int
        let quads: Int
        let multipliers: SIMD4<Float>
        let demosaic: DemosaicMethod
    }

    /// The camera-RGB texture last produced for each key. Values are
    /// pooled textures, so an entry is only trustworthy until something
    /// else renders into the same texture — `storeCameraRGB` evicts any
    /// stale entries pointing at the texture it's recording.
    private var stageCache: [StageKey: MTLTexture] = [:]

    func cachedCameraRGB(for key: StageKey) -> MTLTexture? {
        stageCache[key]
    }

    func storeCameraRGB(_ texture: MTLTexture, for key: StageKey) {
        stageCache = stageCache.filter { $0.value !== texture }
        stageCache[key] = texture
    }

    public init(file: RawFile, gpu: GPUContext) throws {
        let buffer: MTLBuffer?
        switch file.summary.sourceKind {
        case .bayer: buffer = file.sensorPlane.flatMap { gpu.makeSharedBuffer(wrapping: $0) }
        case .linearRGB: buffer = file.linearPlane.flatMap { gpu.makeSharedBuffer(wrapping: $0) }
        }
        guard let buffer else {
            throw RenderError.gpuBufferAllocationFailed
        }
        self.file = file
        self.gpu = gpu
        self.sensorBuffer = buffer

        let isLinear = file.summary.sourceKind == .linearRGB
        let gain = isLinear ? powf(2, file.summary.baselineExposure) : 1
        self.sourceGain = gain
        self.highlightClipScale = isLinear ? (file.summary.mergeInfo?.clipLevel ?? 1) * gain : 1
        self.lensCorrectionAlreadyApplied = isLinear && file.summary.mergeInfo?.lensApplied == true

        let asShot = ColorKit.normalizedWhiteBalance(file.summary.cameraMultipliers)
        self.asShotMultipliers = asShot

        let cameraProfile = file.cameraToXYZMatrixRaw
            .flatMap { ColorKit.CameraColorProfile(cameraToXYZRowMajor: $0) }
        self.profile = cameraProfile
        self.asShotWhiteBalance = cameraProfile?.whiteBalance(fromMultipliers: asShot)
            ?? ColorKit.WhiteBalance()

        let summary = file.summary
        let db = LensfunDatabase.shared
        if lensCorrectionAlreadyApplied {
            self.lensCorrection = nil
        } else if let match = LensMatcher.match(cameraMake: summary.cameraMake, cameraModel: summary.cameraModel,
                                         lensName: summary.lensModel, identity: summary.lens,
                                         focal: summary.focalLength, in: db) {
            self.lensCorrection = LensCorrection.resolve(
                match, focal: Float(summary.focalLength), aperture: Float(summary.aperture),
                imageWidth: summary.rawWidth, imageHeight: summary.rawHeight,
                databaseVersion: db.version)
        } else {
            self.lensCorrection = nil
        }
    }

    /// A stored edit as this image's renders must read it: geometry saved
    /// before the sensor plane was cut to the active area is moved onto
    /// it (`EditStack.migratingGeometry(to:)`). Every path that turns a
    /// stored stack into parameters for an open file goes through here.
    public func stackForThisImage(_ stack: EditStack) -> EditStack {
        stack.migratingGeometry(to: file.summary.activeArea)
    }

    /// The multipliers to render with, for a given white balance setting.
    ///
    /// `.asShot` returns the camera's own values rather than round-tripping
    /// through the temperature conversion, which would introduce the
    /// approximation error of the locus search for no benefit.
    public func multipliers(for whiteBalance: ColorKit.WhiteBalance) -> SIMD4<Float> {
        guard !whiteBalance.isAsShot, let profile else { return asShotMultipliers }
        return profile.multipliers(for: whiteBalance)
    }

    /// Where highlight reconstruction takes each channel to be clipped, in
    /// the camera-RGB seam's units, for a render with these multipliers.
    /// The order matters: the seam holds stored value x multiplier x
    /// `sourceGain`, so a stored value at the file's clip level lands at
    /// clip level x multiplier x gain, which is what `highlightClipScale`
    /// already folds together.
    public func highlightClipLevel(multipliers: SIMD4<Float>) -> SIMD3<Float> {
        SIMD3(multipliers.x, multipliers.y, multipliers.z) * highlightClipScale
    }

    /// Returns a texture of the requested shape and role, reusing a pooled
    /// one when both match a previous request in the current pool.
    ///
    /// Caveat: a texture handed back here stays owned by the session, so a
    /// second render at the same size and role, in the same pool,
    /// overwrites the first result.
    /// That suits a viewport, which draws each frame immediately. Anything
    /// needing to hold a result while rendering again must copy it out.
    func texture(width: Int, height: Int,
                  pixelFormat: MTLPixelFormat, role: TextureRole) throws -> MTLTexture {
        let key = TextureKey(width: width, height: height,
                              pixelFormat: pixelFormat.rawValue, role: role, pool: currentPool)
        if let existing = texturePool[key] {
            return existing
        }
        guard let created = gpu.makePrivateTexture(width: width, height: height,
                                                    pixelFormat: pixelFormat) else {
            throw RenderError.gpuBufferAllocationFailed
        }
        texturePool[key] = created
        return created
    }

    /// How much GPU memory this session holds, for diagnostics and for
    /// deciding when to evict sessions.
    public var approximateBytesHeld: Int {
        var total = sensorBuffer.length
        for (key, _) in texturePool {
            let bytesPerPixel: Int
            switch MTLPixelFormat(rawValue: key.pixelFormat) {
            case .some(.rgba16Float): bytesPerPixel = 8
            case .some(.rg32Float):   bytesPerPixel = 8
            case .some(.r32Float):    bytesPerPixel = 4
            case .some(.r16Float):    bytesPerPixel = 2
            default:                   bytesPerPixel = 8
            }
            total += key.width * key.height * bytesPerPixel
        }
        total += brushMasks?.texture.allocatedSize ?? 0
        total += aiDenoisedCameraRGB?.allocatedSize ?? 0
        return total
    }

    /// Drops pooled textures, keeping the session usable (the sensor buffer
    /// stays). For memory pressure, or when a zoom level won't return.
    public func releasePooledTextures() {
        texturePool.removeAll()
        stageCache.removeAll()
    }

    /// Runs `body` (normally one or more `RenderPipeline.render` calls) with
    /// its pooled textures taken from `pool`.
    public func withTexturePool<T>(_ pool: TexturePool, _ body: () throws -> T) rethrows -> T {
        let saved = currentPool
        currentPool = pool
        defer { currentPool = saved }
        return try body()
    }

    /// Drops one pool's textures, and any demosaic cached in them, leaving
    /// the other pools as they are.
    public func releasePooledTextures(in pool: TexturePool) {
        let released = texturePool.filter { $0.key.pool == pool }.map(\.value)
        guard !released.isEmpty else { return }
        texturePool = texturePool.filter { $0.key.pool != pool }
        stageCache = stageCache.filter { entry in !released.contains { $0 === entry.value } }
    }

    /// Gives memory back when macOS runs short, keeping the session usable:
    /// everything dropped is rebuilt by the next render that needs it.
    ///
    /// A warning drops the pooled textures and the demosaic cache, which
    /// cost one render to rebuild. Textures the caller still holds (the
    /// layers on screen) stay alive through their own references, so the
    /// picture doesn't change. Critical also drops the brush mask
    /// rasters and the neural denoise result. The latter costs about 11 s
    /// to recompute, which is why nothing short of critical touches it;
    /// the caller decides when to run it again. Returns whether the
    /// denoise result was dropped.
    @discardableResult
    public func releaseMemory(for level: MemoryPressureLevel) -> Bool {
        guard level >= .warning else { return false }
        releasePooledTextures()
        guard level == .critical else { return false }
        brushMasks = nil
        placeholderMasks = nil
        let hadDenoise = aiDenoisedCameraRGB != nil
        setAIDenoised(nil, model: nil)
        return hadDenoise
    }
}
