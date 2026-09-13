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

    /// The sensor plane, uploaded once (DESIGN.md §7.2: shared storage,
    /// because the CPU writes it and the GPU reads it).
    let sensorBuffer: MTLBuffer

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
        case lensCorrected  // camera RGB after lens corrections
        case blurA          // sharpening: horizontal blur of luminance
        case blurB          // sharpening: full blur of luminance
        case sharpened      // final output when sharpening ran (tile)
        case sharpenedPreview
    }

    private struct TextureKey: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: UInt
        let role: TextureRole
    }

    private var texturePool: [TextureKey: MTLTexture] = [:]

    /// Rasterized brush masks, created on first use.
    private var brushMasks: BrushMaskSet?
    /// A 1x1 array texture to bind when there are no brush masks: Metal
    /// requires every declared texture slot to be bound.
    private var placeholderMasks: MTLTexture?

    /// Pixels for AI-generated masks, keyed by local id. Set by the app
    /// after MLKit produces them; the session only stores and uploads.
    private var aiMasks: [UUID: MaskBitmap] = [:]

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
    struct StageKey: Hashable {
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
        guard let plane = file.rawSensorPlane(),
              let buffer = gpu.makeSharedBuffer(from: plane) else {
            throw RenderError.gpuBufferAllocationFailed
        }
        self.file = file
        self.gpu = gpu
        self.sensorBuffer = buffer

        let asShot = ColorKit.normalizedWhiteBalance(file.summary.cameraMultipliers)
        self.asShotMultipliers = asShot

        let cameraProfile = file.cameraToXYZMatrixRaw
            .flatMap { ColorKit.CameraColorProfile(cameraToXYZRowMajor: $0) }
        self.profile = cameraProfile
        self.asShotWhiteBalance = cameraProfile?.whiteBalance(fromMultipliers: asShot)
            ?? ColorKit.WhiteBalance()

        let summary = file.summary
        let db = LensfunDatabase.shared
        if let match = LensMatcher.match(cameraMake: summary.cameraMake, cameraModel: summary.cameraModel,
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

    /// The multipliers to render with, for a given white balance setting.
    ///
    /// `.asShot` returns the camera's own values rather than round-tripping
    /// through the temperature conversion, which would introduce the
    /// approximation error of the locus search for no benefit.
    public func multipliers(for whiteBalance: ColorKit.WhiteBalance) -> SIMD4<Float> {
        guard !whiteBalance.isAsShot, let profile else { return asShotMultipliers }
        return profile.multipliers(for: whiteBalance)
    }

    /// Returns a texture of the requested shape and role, reusing a pooled
    /// one when both match a previous request.
    ///
    /// Caveat: a texture handed back here stays owned by the session, so a
    /// second render at the same size and role overwrites the first result.
    /// That suits a viewport, which draws each frame immediately. Anything
    /// needing to hold a result while rendering again must copy it out.
    func texture(width: Int, height: Int,
                  pixelFormat: MTLPixelFormat, role: TextureRole) throws -> MTLTexture {
        let key = TextureKey(width: width, height: height,
                              pixelFormat: pixelFormat.rawValue, role: role)
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

    /// Frees the RCD intermediates while keeping the sensor buffer and the
    /// viewport textures. Worth calling after an export, since those
    /// buffers are the largest thing the session holds and won't be needed
    /// again until the next full-resolution render.
    public func releaseRCDIntermediates() {
        let rcdRoles: Set<TextureRole> = [.rcdVHDir, .rcdLowPass, .rcdDiagonal,
                                           .rcdPQDir, .rcdScratch]
        texturePool = texturePool.filter { !rcdRoles.contains($0.key.role) }
        // The cached camera-RGB textures aren't RCD intermediates, so they
        // survive this and the cache stays valid.
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
        return total
    }

    /// Drops pooled textures, keeping the session usable (the sensor buffer
    /// stays). For memory pressure, or when a zoom level won't return.
    public func releasePooledTextures() {
        texturePool.removeAll()
        stageCache.removeAll()
    }
}
