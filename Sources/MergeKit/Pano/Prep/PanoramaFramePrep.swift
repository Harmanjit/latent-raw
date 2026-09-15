import Foundation
import Metal
import PixelEngine
import RawCore
import ColorKit

// Photos in, prepared frames out: the panorama's stage 2 (docs/PhotoMerge.md
// section 4). The geometry measures the small copies (`input(for:)`); the
// stitcher warps the full-size ones (`prepare`).

/// Why a panorama's photos couldn't be prepared or laid out.
public enum PanoramaError: Error, Equatable, LocalizedError {
    case tooFewPhotos
    case unreadable(fileName: String, reason: String)
    /// Only Bayer raws and linear DNGs (HDR merges) can be stitched.
    case unsupportedSource(fileName: String)
    /// The photos come from different cameras, or were taken at different
    /// focal lengths: they can't share one camera model.
    case differentCameras(fileName: String)
    case gpuUnavailable(reason: String)
    /// The photos don't form a panorama: why, in the dialog's words.
    case notAPanorama(reason: String)

    public var errorDescription: String? {
        switch self {
        case .tooFewPhotos: "A panorama needs at least two photos."
        case .unreadable(let name, let reason): "\(name) couldn't be read (\(reason))."
        case .unsupportedSource(let name): "\(name) isn't a raw photo or an HDR merge, so it can't be stitched."
        case .differentCameras(let name):
            "\(name) was taken with a different camera or focal length from the first photo."
        case .gpuUnavailable(let reason): "The GPU couldn't prepare the photos (\(reason))."
        case .notAPanorama(let reason): "These photos don't form a panorama: \(reason)"
        }
    }
}

/// Opens a panorama's photos and prepares them for the geometry and the
/// stitcher.
///
/// **Order.** Photos are sorted by capture time (then file name, for photos
/// taken within the same second): a panorama is shot turning one way, so
/// capture order is the order around the panorama, and neighbours in time
/// are the pairs that overlap.
///
/// **One white balance.** Every frame is demosaiced with the first photo's
/// as-shot multipliers, which are then divided back out (as the HDR merge
/// does with its median frame), so each frame is demosaiced alike and none
/// carries its own white balance into the panorama.
///
/// Not Sendable: used from one task.
public final class PanoramaFramePrep {
    public let gpu: GPUContext
    let kernels: MergePanoPrepKernels

    /// Full-resolution pixels per thumbnail texel: every geometry decision is
    /// made on a 1/8-scale copy (docs/PhotoMerge.md section 4). A 24 MP
    /// photo's is 752 x 502, 1.5 MB of floats.
    public static let thumbnailSpan = 8

    public init(gpu: GPUContext) {
        self.gpu = gpu
        kernels = MergePanoPrepKernels(gpu: gpu)
    }

    /// One photo of the panorama, opened for its metadata only.
    public struct Photo: Sendable {
        public let url: URL
        public let summary: RawSummary
        public let metadata: PanoramaFrameMetadata
        /// The Lensfun profile its lens is corrected with, nil if none.
        public let lens: MergePanoPrepKernels.Lens?
    }

    /// The photos at `urls`, read for metadata and sorted into capture order.
    ///
    /// - Throws: `PanoramaError` when fewer than two, unreadable, not raw
    ///   photos, or not from one camera at one focal length.
    public func photos(_ urls: [URL]) throws -> [Photo] {
        guard urls.count >= 2 else { throw PanoramaError.tooFewPhotos }
        var photos: [Photo] = []
        for url in urls {
            let summary: RawSummary
            do {
                summary = try RawFile(path: url.path, metadataOnly: true).summary
            } catch {
                throw PanoramaError.unreadable(fileName: url.lastPathComponent, reason: String(describing: error))
            }
            switch summary.cfaPattern {
            case .bayer, .linearRGB: break
            default: throw PanoramaError.unsupportedSource(fileName: url.lastPathComponent)
            }
            let orientation = MergePanoPrepKernels.Orientation(summary: summary)
            let crop = summary.lens.cropFactor > 0 ? summary.lens.cropFactor
                : MergePanoPrepKernels.Lens.cameraCropFactor(make: summary.cameraMake, model: summary.cameraModel) ?? 0
            let metadata = PanoramaFrameMetadata(
                name: url.lastPathComponent, captureTime: summary.captureTime,
                width: orientation.uprightWidth, height: orientation.uprightHeight,
                focalLengthMillimetres: summary.focalLength, cropFactor: crop,
                exposureTime: summary.shutter, iso: summary.iso, aperture: summary.aperture)
            photos.append(Photo(url: url, summary: summary, metadata: metadata,
                                lens: MergePanoPrepKernels.Lens.profile(for: summary)))
        }
        let first = photos[0].summary
        for photo in photos.dropFirst() {
            let s = photo.summary
            let sameFocal = abs(s.focalLength - first.focalLength) <= max(0.01 * first.focalLength, 0.05)
            guard s.cameraMake == first.cameraMake, s.cameraModel == first.cameraModel,
                  s.rawWidth == first.rawWidth, s.rawHeight == first.rawHeight, sameFocal else {
                throw PanoramaError.differentCameras(fileName: photo.url.lastPathComponent)
            }
        }
        return photos.sorted {
            $0.summary.captureTime != $1.summary.captureTime ? $0.summary.captureTime < $1.summary.captureTime
                : $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    /// The white balance every frame is demosaiced with: the first photo's
    /// as-shot multipliers, normalised to green (unit for a file without a
    /// usable one).
    public static func sharedMultipliers(_ photos: [Photo]) -> SIMD3<Float> {
        guard let first = photos.first else { return SIMD3(repeating: 1) }
        let m = ColorKit.normalizedWhiteBalance(first.summary.cameraMultipliers)
        let rgb = SIMD3<Float>(m.x, m.y, m.z)
        guard rgb.x.isFinite, rgb.z.isFinite, rgb.x > 0, rgb.z > 0 else { return SIMD3(repeating: 1) }
        return rgb
    }

    /// The photo decoded and reduced for the geometry (`thumbnailSpan`).
    public func input(for photo: Photo) throws -> PanoramaFrameInput {
        try autoreleasepool {
            let file = try open(photo)
            let source = try Self.gpuStep { try self.source(for: file, multipliers: SIMD3(repeating: 1)) }
            let reduced = try Self.gpuStep { try kernels.thumbnail(source, span: Self.thumbnailSpan, lens: photo.lens) }
            let thumbnail = PanoramaThumbnail(width: reduced.width, height: reduced.height, span: reduced.span,
                                              rgba: reduced.rgba, clippedShare: reduced.clippedShare)
            return PanoramaFrameInput(metadata: photo.metadata, thumbnail: thumbnail)
        }
    }

    /// The photo prepared at `span` for the stitcher: an `rgba16Float`
    /// texture of lens-corrected, upright camera RGB at unit white balance
    /// with coverage in alpha (`MergePanoPrepKernels.prepare`), sized
    /// `floor(width / span) x floor(height / span)`. Waits for the GPU.
    public func prepare(_ photo: Photo, span: Int, multipliers: SIMD3<Float>,
                        storage: MTLStorageMode = .private) throws -> MTLTexture {
        try autoreleasepool {
            let file = try open(photo)
            let source = try Self.gpuStep { try self.source(for: file, multipliers: multipliers) }
            return try Self.gpuStep { try kernels.prepare(source, span: span, lens: photo.lens, storage: storage) }
        }
    }

    // MARK: - Helpers

    private func open(_ photo: Photo) throws -> RawFile {
        do {
            return try RawFile(path: photo.url.path)
        } catch {
            throw PanoramaError.unreadable(fileName: photo.url.lastPathComponent, reason: String(describing: error))
        }
    }

    private func source(for file: RawFile, multipliers: SIMD3<Float>) throws -> MergePanoPrepKernels.Source {
        switch file.summary.cfaPattern {
        case .bayer:
            // The HDR merge's levels: per-colour black and where the sensor
            // really saturates.
            return .bayer(file, levels: try HDRMerger.levels(for: file, gpu: gpu), multipliers: multipliers)
        case .linearRGB:
            return .linear(file, clipLevel: file.summary.mergeInfo?.clipLevel ?? 1)
        default:
            throw PanoramaError.unsupportedSource(fileName: file.summary.cameraModel)
        }
    }

    static func gpuStep<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as RenderError {
            throw PanoramaError.gpuUnavailable(reason: error.description)
        } catch let error as GPUContextError {
            throw PanoramaError.gpuUnavailable(reason: error.description)
        } catch let error as HDRMergeKernelError {
            throw PanoramaError.gpuUnavailable(reason: error.description)
        }
    }
}
