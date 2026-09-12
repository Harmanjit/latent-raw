import Foundation
import Metal
import simd
import RawCore
import ColorKit

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
        case rcdVHDir       // vertical/horizontal directional discrimination
        case rcdLowPass     // local average for ratio correction
        case rcdDiagonal    // packed P/Q diagonal high-pass statistics
        case rcdPQDir       // diagonal directional discrimination
        case rcdScratch     // ping-pong partner for the RGB passes
    }

    private struct TextureKey: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: UInt
        let role: TextureRole
    }

    private var texturePool: [TextureKey: MTLTexture] = [:]

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
    }
}
