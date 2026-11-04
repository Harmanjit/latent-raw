import Foundation
import CryptoKit
import Metal
import os
import simd
import RawCore

// MARK: - The stored correction

/// Flat-Field Correction (Lightroom's Library › Plug-in Extras ›
/// Flat-Field Correction): a reference raw shot through a diffuser, with
/// the same lens, aperture and focal length, records how the lens and
/// sensor darken and tint the frame away from the centre. Its smoothed
/// per-channel gain map is laid over every photo it is applied to, in
/// camera space, before the lens corrections, which takes out the
/// luminance vignetting and the colour cast a profile can't describe
/// (a tilt-shift lens's off-axis cast, a sensor's corner tint).
///
/// The edit stores where the reference is and which file it was, never
/// the gain map: the map is made from the reference once and cached on
/// this Mac by the file's hash (`FlatFieldCache`), and made again from the
/// file whenever the cache doesn't have it.
public struct FlatFieldCorrection: Codable, Equatable, Sendable {
    /// The reference's path relative to the photo's folder, such as
    /// "Flats/DSC_0001.NEF" or "../Flats/DSC_0001.NEF", so the pair
    /// survives moving or renaming the folder tree they share.
    public var reference: String
    /// "sha256:" and the reference file's SHA-256 in hex: names the cached
    /// gain map, and tells whether a file found at `reference` is still
    /// the one the correction was made from.
    public var hash: String
    /// 0…1, the Amount slider.
    public var amount: Float

    public init(reference: String, hash: String, amount: Float = 1) {
        self.reference = reference
        self.hash = hash
        self.amount = amount
    }

    /// The reference's file name, for the panel.
    public var referenceName: String { (reference as NSString).lastPathComponent }

    public var isActive: Bool { amount > 0 }

    /// Checked when a stack is read: a hand-edited sidecar can't hand the
    /// pipeline an amount outside 0…1, or a hash that names no file.
    var sanitized: FlatFieldCorrection? {
        guard hash.hasPrefix(Self.hashPrefix), hash.count < 200, !reference.isEmpty, reference.count < 4096 else {
            return nil
        }
        var out = self
        out.amount = amount.isFinite ? min(max(amount, 0), 1) : 1
        return out
    }

    // MARK: Where the reference is

    /// `reference`'s path relative to the folder `photo` is in.
    public static func relativePath(from photo: URL, to reference: URL) -> String {
        let from = photo.deletingLastPathComponent().standardizedFileURL.pathComponents
        let to = reference.standardizedFileURL.pathComponents
        var shared = 0
        while shared < from.count, shared < to.count, from[shared] == to[shared] { shared += 1 }
        // Nothing in common but the root: an absolute path is clearer.
        guard shared > 1 else { return reference.standardizedFileURL.path }
        let up = Array(repeating: "..", count: from.count - shared)
        return (up + to[shared...]).joined(separator: "/")
    }

    /// Where the reference should be for the photo at `photo`.
    public func referenceURL(forPhoto photo: URL) -> URL {
        if reference.hasPrefix("/") { return URL(fileURLWithPath: reference).standardizedFileURL }
        return photo.deletingLastPathComponent().appendingPathComponent(reference).standardizedFileURL
    }

    // MARK: Which file it is

    public static let hashPrefix = "sha256:"

    /// The value `hash` holds for the file at `url`. Memory-mapped, so a
    /// 50 MB raw isn't copied first; SHA-256 runs in hardware.
    public static func hash(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return hashPrefix + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Why a flat-field reference couldn't be used.
public enum FlatFieldError: Error, LocalizedError, Equatable {
    /// The reference's centre is too dark to measure a falloff against.
    case tooDark(String)
    /// The reference's centre is clipped, so its falloff is understated.
    case overexposed(String)
    /// The photo's sensor has another shape than the reference's.
    case shapeMismatch(String)
    /// No file at the stored path.
    case referenceMissing(String)
    /// A file at the stored path, but not the one the correction was made from.
    case referenceChanged(String)

    public var errorDescription: String? {
        switch self {
        case .tooDark(let name):
            "\(name) is too dark to use as a flat-field reference. Shoot it brighter, about two stops over the meter."
        case .overexposed(let name):
            "\(name) is overexposed in the centre, so its falloff can't be measured. Shoot it a stop or two darker."
        case .shapeMismatch(let name):
            "\(name) has another sensor shape than the reference, so the correction can't be laid over it."
        case .referenceMissing(let path):
            "The flat-field reference \(path) can't be found."
        case .referenceChanged(let path):
            "The flat-field reference \(path) is no longer the file the correction was made from."
        }
    }
}

// MARK: - The gain map

/// The correction itself: per-channel gains on a coarse grid over the
/// sensor, smooth enough to sample bilinearly, 1 at the reference's
/// centre. Multiplying camera RGB by it divides out the reference's
/// falloff and tint, channel by channel; it is a ratio, so the photo's
/// white balance doesn't change it.
public struct FlatFieldGainMap: Codable, Equatable, Sendable {
    /// Cells along the long edge. Vignetting and lens casts change over a
    /// good fraction of the frame, so 64 is plenty, and the map stays
    /// small enough to keep every one in memory.
    public static let longEdgeCells = 64
    /// The most a channel is lifted or held back: a corner four stops
    /// down is about as much as any lens gives, and beyond that the
    /// reference itself is mostly noise.
    public static let gainRange: ClosedRange<Float> = 0.25...16

    public var width: Int
    public var height: Int
    /// RGB gains, row by row, three per cell.
    public var gains: [Float]
    /// The reference sensor's width over its height, so a map is never
    /// stretched over another sensor's shape.
    public var aspect: Float

    public init(width: Int, height: Int, gains: [Float], aspect: Float) {
        self.width = width
        self.height = height
        self.gains = gains
        self.aspect = aspect
    }

    public func gain(x: Int, y: Int) -> SIMD3<Float> {
        let i = (y * width + x) * 3
        return SIMD3(gains[i], gains[i + 1], gains[i + 2])
    }

    /// Whether a sensor of `aspect` takes this map: within 2 %, so a
    /// body's crop modes are told apart but its own frames always fit.
    public func fits(aspect other: Float) -> Bool {
        other > 0 && abs(other / aspect - 1) < 0.02
    }

    var isUsable: Bool {
        width >= 2 && height >= 2 && width <= 1024 && height <= 1024 && gains.count == width * height * 3
            && gains.allSatisfy { $0.isFinite && $0 > 0 } && aspect.isFinite && aspect > 0
    }

    /// The map from a whole-frame render of the reference in camera RGB
    /// (`pixels`, four floats each, `width` by `height`): averaged into
    /// cells, smoothed, and each channel divided into its value at the
    /// centre. `clipLevel` is where each channel clips in the render's
    /// units, to refuse a reference too dark or too bright to measure.
    public static func make(cameraRGB pixels: [Float], width: Int, height: Int,
                            clipLevel: SIMD3<Float>, aspect: Float, name: String) throws -> FlatFieldGainMap {
        precondition(pixels.count >= width * height * 4)
        let long = max(width, height)
        let scale = Double(min(longEdgeCells, long)) / Double(long)
        let gw = max(2, Int((Double(width) * scale).rounded()))
        let gh = max(2, Int((Double(height) * scale).rounded()))

        // Box averages: each cell its share of the pixels.
        var cells = [SIMD3<Float>](repeating: .zero, count: gw * gh)
        for cy in 0..<gh {
            let y0 = cy * height / gh, y1 = max(y0 + 1, (cy + 1) * height / gh)
            for cx in 0..<gw {
                let x0 = cx * width / gw, x1 = max(x0 + 1, (cx + 1) * width / gw)
                var sum = SIMD3<Double>.zero
                for y in y0..<min(y1, height) {
                    var i = (y * width + x0) * 4
                    for _ in x0..<min(x1, width) {
                        sum += SIMD3(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
                        i += 4
                    }
                }
                let n = Double(max(1, (min(y1, height) - y0) * (min(x1, width) - x0)))
                cells[cy * gw + cx] = SIMD3<Float>(sum / n)
            }
        }
        cells = smoothed(cells, width: gw, height: gh)

        // The centre: the cells within a tenth of the frame of it.
        var centreSum = SIMD3<Float>.zero
        var centreCount: Float = 0
        for cy in 0..<gh {
            for cx in 0..<gw {
                let u = (Float(cx) + 0.5) / Float(gw) - 0.5, v = (Float(cy) + 0.5) / Float(gh) - 0.5
                if abs(u) <= 0.1, abs(v) <= 0.1 { centreSum += cells[cy * gw + cx]; centreCount += 1 }
            }
        }
        if centreCount == 0 { centreSum = cells[(gh / 2) * gw + gw / 2]; centreCount = 1 }
        let centre = centreSum / centreCount
        let relative = centre / simd_max(clipLevel, SIMD3(repeating: 1e-6))
        guard relative.min() > 0.02 else { throw FlatFieldError.tooDark(name) }
        guard relative.max() < 0.97 else { throw FlatFieldError.overexposed(name) }

        var gains = [Float]()
        gains.reserveCapacity(gw * gh * 3)
        for cell in cells {
            let g = centre / simd_max(cell, centre * 0.01)
            for c in 0..<3 { gains.append(min(max(g[c], gainRange.lowerBound), gainRange.upperBound)) }
        }
        return FlatFieldGainMap(width: gw, height: gh, gains: gains, aspect: aspect)
    }

    /// Two passes of a 1-2-1 blur each way, edges clamped: takes the last
    /// of the noise and any dust shadow out of the cells.
    static func smoothed(_ cells: [SIMD3<Float>], width w: Int, height h: Int) -> [SIMD3<Float>] {
        var a = cells
        var b = cells
        for _ in 0..<2 {
            for y in 0..<h {
                for x in 0..<w {
                    let l = a[y * w + max(0, x - 1)], r = a[y * w + min(w - 1, x + 1)]
                    b[y * w + x] = (l + a[y * w + x] * 2 + r) / 4
                }
            }
            for y in 0..<h {
                for x in 0..<w {
                    let u = b[max(0, y - 1) * w + x], d = b[min(h - 1, y + 1) * w + x]
                    a[y * w + x] = (u + b[y * w + x] * 2 + d) / 4
                }
            }
        }
        return a
    }

    /// Opens the reference at `url` and makes its map: a binned render of
    /// the whole sensor in camera RGB (about 512 pixels across), as shot,
    /// read back and reduced.
    public static func analyse(referenceAt url: URL, gpu: GPUContext) throws -> FlatFieldGainMap {
        let file = try RawFile(path: url.path)
        let summary = file.summary
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var parameters = EditParameters()
        parameters.whiteBalance = session.asShotWhiteBalance
        let quads = max(1, max(summary.rawWidth, summary.rawHeight) / 1024)
        defer { session.releasePooledTextures(in: .analysis) }
        let (halfs, width, height) = try session.withTexturePool(.analysis) {
            let texture = try pipeline.renderCameraRGB(session, scale: .binned(quads: quads), parameters: parameters)
            return (try TextureReadback.float16Pixels(of: texture, gpu: gpu), texture.width, texture.height)
        }
        let clip = session.highlightClipLevel(multipliers: session.multipliers(for: parameters.whiteBalance))
        return try make(cameraRGB: halfs.map { Float($0) }, width: width, height: height, clipLevel: clip,
                        aspect: Float(summary.rawWidth) / Float(max(1, summary.rawHeight)),
                        name: url.lastPathComponent)
    }
}

// MARK: - The cache

/// Gain maps by reference hash: in memory for the process, and on disk in
/// Application Support so a photo renders corrected on the next launch
/// without its reference being decoded again. Each map is a few tens of
/// kilobytes. The render pipeline only ever reads it, so a render never
/// waits on a decode: whoever opens or exports a photo calls
/// `ensureGainMap` first.
public final class FlatFieldCache: @unchecked Sendable {
    public static let shared = FlatFieldCache(directory: FlatFieldCache.defaultDirectory)

    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("latent/flatfield", isDirectory: true)
    }

    let directory: URL?
    private let lock = NSLock()
    private var maps: [String: FlatFieldGainMap] = [:]
    private var textures: [String: MTLTexture] = [:]
    /// References that couldn't be found or read this session, so every
    /// render and thumbnail doesn't try again.
    private var failures: [String: String] = [:]

    public init(directory: URL?) {
        self.directory = directory
    }

    private func fileURL(for hash: String) -> URL? {
        let safe = hash.replacingOccurrences(of: ":", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return directory?.appendingPathComponent(safe + ".json")
    }

    /// The map for `hash`, from memory or disk; nil when this Mac has none.
    public func gainMap(for hash: String) -> FlatFieldGainMap? {
        if let map = lock.withLock({ maps[hash] }) { return map }
        guard let url = fileURL(for: hash), let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode(FlatFieldGainMap.self, from: data), map.isUsable else { return nil }
        lock.withLock { maps[hash] = map }
        return map
    }

    /// Keeps `map` for `hash`, on disk too unless `persist` is false.
    public func store(_ map: FlatFieldGainMap, for hash: String, persist: Bool = true) {
        lock.withLock {
            maps[hash] = map
            textures[hash] = nil
            failures[hash] = nil
        }
        guard persist, let url = fileURL(for: hash), let data = try? JSONEncoder().encode(map) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            gpuLog.error("Flat-field gain map not saved: \(String(describing: error), privacy: .public)")
        }
    }

    /// Why the last attempt at `hash`'s map failed this session, if it did.
    public func failure(for hash: String) -> String? { lock.withLock { failures[hash] } }

    /// Hashes the reference at `url`, makes its map and keeps it.
    public func makeGainMap(referenceAt url: URL, gpu: GPUContext) throws -> (hash: String, map: FlatFieldGainMap) {
        let hash = try FlatFieldCorrection.hash(ofFileAt: url)
        if let map = gainMap(for: hash) { return (hash, map) }
        let map = try FlatFieldGainMap.analyse(referenceAt: url, gpu: gpu)
        store(map, for: hash)
        return (hash, map)
    }

    /// Makes sure the map `correction` needs is on hand, making it from the
    /// reference found beside `photo` when it isn't, provided the file
    /// there is still the one the correction names. Returns whether the
    /// map is on hand; a failure is remembered for the session, so it is
    /// tried once, and `failure(for:)` says why.
    @discardableResult
    public func ensureGainMap(for correction: FlatFieldCorrection?, photo: URL, gpu: GPUContext) -> Bool {
        guard let correction else { return true }
        if gainMap(for: correction.hash) != nil { return true }
        if failure(for: correction.hash) != nil { return false }
        let url = correction.referenceURL(forPhoto: photo)
        do {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw FlatFieldError.referenceMissing(correction.reference)
            }
            guard try FlatFieldCorrection.hash(ofFileAt: url) == correction.hash else {
                throw FlatFieldError.referenceChanged(correction.reference)
            }
            store(try FlatFieldGainMap.analyse(referenceAt: url, gpu: gpu), for: correction.hash)
            return true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            lock.withLock { failures[correction.hash] = message }
            return false
        }
    }

    /// The map for `hash` as a small float texture, made once.
    func texture(for hash: String, gpu: GPUContext) -> (texture: MTLTexture, map: FlatFieldGainMap)? {
        guard let map = gainMap(for: hash) else { return nil }
        if let texture = lock.withLock({ textures[hash] }) { return (texture, map) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: map.width,
                                                                  height: map.height, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else { return nil }
        var rgba = [Float]()
        rgba.reserveCapacity(map.width * map.height * 4)
        for i in 0..<(map.width * map.height) {
            rgba += [map.gains[i * 3], map.gains[i * 3 + 1], map.gains[i * 3 + 2], 1]
        }
        texture.replace(region: MTLRegionMake2D(0, 0, map.width, map.height), mipmapLevel: 0,
                        withBytes: rgba, bytesPerRow: map.width * 16)
        lock.withLock { textures[hash] = texture }
        return (texture, map)
    }
}

// MARK: - The stage

/// Mirror of `FlatFieldParams` in FlatField.metal.
struct FlatFieldParamsGPU {
    var sensorSize: SIMD2<Float>
    var origin: SIMD2<Float>
    var binSpan: Float
    var amount: Float
    var padding = SIMD2<Float>(0, 0)
}

/// Stage 6b (RenderPipeline): the gain map laid over camera RGB after the
/// spot removal and before the lens corrections, so the lens stage's own
/// vignetting and the transform see the flattened frame.
enum FlatFieldStage {
    static func encode(input: MTLTexture, gain: MTLTexture, amount: Float, sensorSize: SIMD2<Float>,
                       sensorRect: CGRect, binSpan: Float, session: ImageSession, preview: Bool,
                       gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let output = try session.texture(width: input.width, height: input.height, pixelFormat: .rgba16Float,
                                         role: preview ? .flatFieldPreview : .flatField)
        let pso = try gpu.lazyPipeline(.flatFieldApply)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        var params = FlatFieldParamsGPU(sensorSize: sensorSize,
                                        origin: SIMD2(Float(sensorRect.origin.x), Float(sensorRect.origin.y)),
                                        binSpan: binSpan, amount: amount)
        encoder.setComputePipelineState(pso)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(gain, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<FlatFieldParamsGPU>.stride, index: 0)
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (input.width + tw - 1) / tw, height: (input.height + th - 1) / th,
                                             depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        return output
    }
}
