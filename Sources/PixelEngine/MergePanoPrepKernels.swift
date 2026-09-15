import Foundation
import LensKit
import Metal
import RawCore
import simd
import Synchronization

// The GPU half of Photo Merge's panorama frame preparation: the kernels in
// Shaders/MergePanoPrep.metal, encoded for MergeKit. MergeKit/Pano/Prep
// decides what to prepare; these turn one photo into a lens-corrected,
// upright frame (and the small copy the panorama geometry measures).

/// Panorama frame preparation's GPU kernels.
///
/// **What a prepared frame is.** An `rgba16Float` texture of camera RGB at
/// unit white balance (black subtracted, white = 1), with the lens's
/// distortion, transverse chromatic aberration and vignetting corrected,
/// turned upright, and alpha as coverage: 1 where the corrected frame shows
/// the photo, 0 (with black colour) where it would read from outside it.
/// Texel (i, j) covers the upright photo's full-resolution pixels
/// `[i·span, (i+1)·span) x [j·span, (j+1)·span)`, the convention the
/// panorama's camera model (`PanoramaCamera`) is written in.
///
/// **Sizes.** At span 1 the photo is demosaiced with RCD; at span 2 or more
/// each texel is the mean of a whole `span x span` block of photosites, per
/// colour, with nothing interpolated (a Bayer quad already holds every
/// colour, as `mergeHDRBinnedAnalysis` explains).
///
/// **Memory.** At full resolution the photo is demosaiced a band at a time:
/// each band of output rows reads a window of the sensor only as big as the
/// lens correction needs for those rows (plus an apron that keeps RCD's
/// own edge out of it), so a 24 MP frame needs its finished texture plus
/// one window's worth of RCD scratch, never the whole photo demosaiced.
///
/// **Pipelines** are built the first time they are used and kept by this
/// object (not `GPUContext`'s lazy table, which the panorama stitcher's
/// kernels are being added to in parallel).
///
/// Not for use from several threads at once.
public final class MergePanoPrepKernels: @unchecked Sendable {
    public let gpu: GPUContext
    private let renderPipeline: RenderPipeline
    private let pipelines = Mutex<[String: MTLComputePipelineState]>([:])

    public init(gpu: GPUContext) {
        self.gpu = gpu
        renderPipeline = RenderPipeline(gpu: gpu)
    }

    /// Sensor pixels of RCD input kept around every point a band reads:
    /// RCD mirrors instead of reading real neighbours up to 11 pixels in
    /// from its input's edge, and a bilinear read needs one more.
    static let windowApron = 16
    /// The most sensor pixels one full-resolution window demosaics, about
    /// 150 MB of RCD scratch (36 bytes a pixel).
    static let windowPixelBudget = 4_000_000
    /// Output pixels per command buffer for the lens pass (as the warp's
    /// bands): no single GPU command long enough to stall the display.
    static let passBandPixels = 4_000_000

    // MARK: - Geometry

    /// How the upright image sits on the sensor: LibRaw's `flip` as a map
    /// from upright image points to sensor points.
    public struct Orientation: Sendable, Equatable {
        public let rotation: ImageRotation
        /// The active area, in sensor pixels.
        public let sensorWidth: Int
        public let sensorHeight: Int

        public init(rotation: ImageRotation, sensorWidth: Int, sensorHeight: Int) {
            self.rotation = rotation
            self.sensorWidth = sensorWidth
            self.sensorHeight = sensorHeight
        }

        public init(summary: RawSummary) {
            self.init(rotation: ImageRotation(libRawFlip: summary.orientation),
                      sensorWidth: summary.rawWidth, sensorHeight: summary.rawHeight)
        }

        /// The upright photo's size in full-resolution pixels.
        public var uprightWidth: Int { rotation.swapsAxes ? sensorHeight : sensorWidth }
        public var uprightHeight: Int { rotation.swapsAxes ? sensorWidth : sensorHeight }

        /// The affine map upright point -> sensor point, as (a, b, c, d, e, f)
        /// with sensor = (a·x + b·y + c, d·x + e·y + f). `ImageRotation`'s
        /// `sensorPoint(fromImagePoint:)` written as numbers the kernel reads.
        public var uprightToSensor: (a: Double, b: Double, c: Double, d: Double, e: Double, f: Double) {
            let w = Double(sensorWidth), h = Double(sensorHeight)
            switch rotation {
            case .none: return (1, 0, 0, 0, 1, 0)
            case .cw90: return (0, 1, 0, -1, 0, h)
            case .cw180: return (-1, 0, w, 0, -1, h)
            case .cw270: return (0, -1, w, 1, 0, 0)
            }
        }

        public func sensorPoint(uprightPoint p: SIMD2<Double>) -> SIMD2<Double> {
            let m = uprightToSensor
            return SIMD2(m.a * p.x + m.b * p.y + m.c, m.d * p.x + m.e * p.y + m.f)
        }
    }

    /// The lens corrections a frame is prepared with: a profile resolved at
    /// the photo's focal length and aperture (`LensCorrection`). Its auto
    /// scale is ignored, see `mergePanoPrepLens`.
    public struct Lens: Sendable, Equatable {
        public var correction: LensCorrection

        public init(_ correction: LensCorrection) {
            self.correction = correction
        }

        /// The profile the editor would use for this photo (the same lookup
        /// as `ImageSession`), or nil when there is none. A Photo Merge
        /// result with its lens correction already baked in has none.
        public static func profile(for summary: RawSummary) -> Lens? {
            guard summary.mergeInfo?.lensApplied != true else { return nil }
            let db = LensfunDatabase.shared
            guard let match = LensMatcher.match(cameraMake: summary.cameraMake, cameraModel: summary.cameraModel,
                                                lensName: summary.lensModel, identity: summary.lens,
                                                focal: summary.focalLength, in: db) else { return nil }
            let correction = LensCorrection.resolve(match, focal: Float(summary.focalLength),
                                                    aperture: Float(summary.aperture),
                                                    imageWidth: summary.rawWidth, imageHeight: summary.rawHeight,
                                                    databaseVersion: db.version)
            return correction.isEmpty ? nil : Lens(correction)
        }

        /// The camera's crop factor from the Lensfun database (1 for full
        /// frame), for cameras whose files don't record one; nil if unknown.
        public static func cameraCropFactor(make: String, model: String) -> Double? {
            LensMatcher.findCamera(make: make, model: model, in: LensfunDatabase.shared).map { Double($0.cropFactor) }
        }

        public var profileName: String { correction.profileName }

        /// Where the corrected photo's sensor point `p` reads from in the
        /// uncorrected one: green, red and blue. The CPU twin of the kernel,
        /// for planning windows and for tests.
        public func sourcePoints(sensorPoint p: SIMD2<Double>, sensorWidth: Int, sensorHeight: Int)
        -> (green: SIMD2<Double>, red: SIMD2<Double>, blue: SIMD2<Double>) {
            let size = SIMD2(Double(sensorWidth), Double(sensorHeight))
            let halfShort = min(size.x, size.y) / 2
            let centre = size / 2
            let crop = Double(correction.cropRatio)
            let cu = p - centre
            let ru = simd_length(cu) / halfShort * crop
            let factor = Double(correction.distortion?.factor(atUndistortedRadius: Float(ru)) ?? 1)
            let cd = cu * factor
            guard let tca = correction.tca else { return (cd + centre, cd + centre, cd + centre) }
            let rd = simd_length(cd) / halfShort * crop
            let red = SIMD3<Double>(tca.red), blue = SIMD3<Double>(tca.blue)
            let fr = red.x * rd * rd + red.y * rd + red.z
            let fb = blue.x * rd * rd + blue.y * rd + blue.z
            return (cd + centre, cd * fr + centre, cd * fb + centre)
        }

        /// The factor vignetting correction multiplies the photo's point
        /// that corrected sensor point `p` reads from.
        public func vignettingGain(sensorPoint p: SIMD2<Double>, sensorWidth: Int, sensorHeight: Int) -> Double {
            guard let v = correction.vignetting else { return 1 }
            let size = SIMD2(Double(sensorWidth), Double(sensorHeight))
            let green = sourcePoints(sensorPoint: p, sensorWidth: sensorWidth, sensorHeight: sensorHeight).green
            let rv = simd_length(green - size / 2) / (simd_length(size) / 2) * Double(correction.cropRatio)
            let rv2 = rv * rv
            let k = 1 + Double(v.k1) * rv2 + Double(v.k2) * rv2 * rv2 + Double(v.k3) * rv2 * rv2 * rv2
            return 1 / max(k, 0.05)
        }
    }

    /// The size of a frame prepared at `span`: the upright photo divided by
    /// the span, rounded down, so every texel is a whole block.
    public static func preparedSize(_ orientation: Orientation, span: Int) -> (width: Int, height: Int) {
        (max(1, orientation.uprightWidth / max(1, span)), max(1, orientation.uprightHeight / max(1, span)))
    }

    // MARK: - Sources

    /// What a frame is prepared from.
    public enum Source {
        /// A Bayer raw with its sensor data: its black levels and clipping
        /// point, and the white balance RCD demosaics with (the same for
        /// every frame of the panorama; divided back out).
        case bayer(RawFile, levels: HDRFrameLevels, multipliers: SIMD3<Float>)
        /// A linear DNG (an HDR merge): already demosaiced camera RGB at unit
        /// white balance; `clipLevel` is where it clips (its merge info's).
        case linear(RawFile, clipLevel: Float)

        var file: RawFile {
            switch self {
            case .bayer(let file, _, _), .linear(let file, _): file
            }
        }
    }

    // MARK: - Prepared frames

    /// `source` prepared at `span` (see the type's notes): an `rgba16Float`
    /// texture of `preparedSize` texels. Waits for the GPU.
    ///
    /// - Parameters:
    ///   - lens: the corrections to apply; nil for none (only turned upright).
    ///   - storage: `.shared` to read the result back on the CPU.
    public func prepare(_ source: Source, span: Int, lens: Lens?,
                        storage: MTLStorageMode = .private) throws -> MTLTexture {
        try prepare(source, span: span, lens: lens, storage: storage, windowPixelBudget: Self.windowPixelBudget)
    }

    /// `prepare` with the full-resolution window size chosen, so tests can
    /// check that bands of any size give the same frame.
    func prepare(_ source: Source, span: Int, lens: Lens?, storage: MTLStorageMode,
                 windowPixelBudget: Int) throws -> MTLTexture {
        let span = max(1, span)
        let orientation = Orientation(summary: source.file.summary)
        let size = Self.preparedSize(orientation, span: span)
        let output = try HDRMergeKernels.makeTexture(gpu, width: size.width, height: size.height,
                                                     format: .rgba16Float, storage: storage)
        if span == 1 {
            try prepareFullResolution(source, orientation: orientation, lens: lens, into: output,
                                      windowPixelBudget: windowPixelBudget)
        } else {
            let reduced = try reducedSource(source, span: span, format: .rgba16Float)
            try lensPass(source: reduced.texture, sourceOrigin: .zero, orientation: orientation, span: span,
                         lens: lens, inverseMultipliers: reduced.inverseMultipliers, output: output, clipShare: nil,
                         rows: 0..<size.height)
        }
        return output
    }

    /// A small prepared copy read back to the CPU, for measuring the
    /// panorama's geometry and exposure: `span` blocks averaged (8 in
    /// docs/PhotoMerge.md, "every decision is made on a 1/8-scale copy"),
    /// lens-corrected and upright like `prepare`, plus where it was clipped.
    public struct Thumbnail: Sendable {
        public let width: Int
        public let height: Int
        /// Full-resolution pixels per texel.
        public let span: Int
        /// Camera RGB at unit white balance and coverage (alpha), four
        /// Float32 per texel, row by row.
        public let rgba: [Float]
        /// The share of each texel's photosites that were clipped (1 outside
        /// the photo). All 0 for a linear source, whose clipping is judged
        /// from its values against `clipLevel` instead.
        public let clippedShare: [Float]
    }

    public func thumbnail(_ source: Source, span: Int, lens: Lens?) throws -> Thumbnail {
        let span = max(1, span)
        let orientation = Orientation(summary: source.file.summary)
        let size = Self.preparedSize(orientation, span: span)
        let reduced = try reducedSource(source, span: span, format: .rgba32Float)
        let output = try HDRMergeKernels.makeTexture(gpu, width: size.width, height: size.height,
                                                     format: .rgba32Float, storage: .shared)
        let clip = try HDRMergeKernels.makeTexture(gpu, width: size.width, height: size.height,
                                                   format: .r32Float, storage: .shared)
        try lensPass(source: reduced.texture, sourceOrigin: .zero, orientation: orientation, span: span, lens: lens,
                     inverseMultipliers: reduced.inverseMultipliers, output: output,
                     clipShare: reduced.hasClipShare ? clip : nil, rows: 0..<size.height)
        var rgba = [Float](repeating: 0, count: size.width * size.height * 4)
        output.getBytes(&rgba, bytesPerRow: size.width * 16, from: MTLRegionMake2D(0, 0, size.width, size.height),
                        mipmapLevel: 0)
        var clipped = [Float](repeating: 0, count: size.width * size.height)
        if reduced.hasClipShare {
            clip.getBytes(&clipped, bytesPerRow: size.width * 4, from: MTLRegionMake2D(0, 0, size.width, size.height),
                          mipmapLevel: 0)
        } else if case .linear(_, let clipLevel) = source {
            // A linear source has no photosites left to count: a texel is
            // clipped where a channel reaches its clip level (as the
            // aligner judges clipping), and outside the photo.
            let limit = 0.98 * clipLevel
            for i in 0..<(size.width * size.height)
            where rgba[4 * i + 3] < 0.5 || max(rgba[4 * i], rgba[4 * i + 1], rgba[4 * i + 2]) >= limit {
                clipped[i] = 1
            }
        }
        return Thumbnail(width: size.width, height: size.height, span: span, rgba: rgba, clippedShare: clipped)
    }

    // MARK: - Full resolution in bands

    /// One band of a full-resolution preparation: the output rows it writes
    /// and the sensor window it demosaics for them.
    struct Band: Equatable {
        var rows: Range<Int>
        /// Sensor pixels; the origin is even in both directions.
        var windowX: Int
        var windowY: Int
    }

    /// The bands of a full-resolution preparation and their shared window
    /// size (every band demosaics a window of the same size, so the RCD
    /// scratch textures are made once and reused).
    ///
    /// Each band's window holds every point its rows read (found on a grid
    /// over the band, as `RenderPipeline.lensSourceWindow` does for a region
    /// render) plus `windowApron`. Windows are slid rather than shrunk where
    /// they meet the sensor's edge, so a window's edge is either the sensor's
    /// own edge (where RCD's mirroring is right) or at least an apron away
    /// from anything read.
    static func bandPlan(orientation: Orientation, lens: Lens?,
                         pixelBudget: Int = windowPixelBudget) -> (bands: [Band], windowWidth: Int, windowHeight: Int) {
        let sw = orientation.sensorWidth, sh = orientation.sensorHeight
        let uw = orientation.uprightWidth, uh = orientation.uprightHeight
        // Output rows run across the sensor's columns when the photo is
        // turned a quarter; a window spans the sensor the other way whole.
        let across = orientation.rotation.swapsAxes ? sh : sw
        let rowsPerBand = max(64, min(uh, pixelBudget / max(across, 1) - 2 * windowApron - 64))
        var needed: [(rows: Range<Int>, lo: SIMD2<Double>, hi: SIMD2<Double>)] = []
        var y = 0
        while y < uh {
            let rows = y..<min(uh, y + rowsPerBand)
            var lo = SIMD2<Double>(repeating: .infinity), hi = SIMD2<Double>(repeating: -.infinity)
            let rowSteps = max(1, min(32, rows.count / 16))
            let columnSteps = 64
            for r in 0...rowSteps {
                let v = Double(rows.lowerBound) + 0.5 + Double(r) / Double(rowSteps) * Double(rows.count - 1)
                for c in 0...columnSteps {
                    let u = 0.5 + Double(c) / Double(columnSteps) * Double(uw - 1)
                    let sensor = orientation.sensorPoint(uprightPoint: SIMD2(u, v))
                    let reads = lens?.sourcePoints(sensorPoint: sensor, sensorWidth: sw, sensorHeight: sh)
                        ?? (green: sensor, red: sensor, blue: sensor)
                    for p in [reads.green, reads.red, reads.blue] {
                        lo = simd_min(lo, p)
                        hi = simd_max(hi, p)
                    }
                }
            }
            needed.append((rows, lo, hi))
            y = rows.upperBound
        }
        // Whole pixels, apron added, clamped to the sensor.
        let apron = Double(windowApron)
        let rects = needed.map { band -> (rows: Range<Int>, x0: Int, y0: Int, x1: Int, y1: Int) in
            let x0 = max(0, Int((band.lo.x - apron).rounded(.down)))
            let y0 = max(0, Int((band.lo.y - apron).rounded(.down)))
            let x1 = min(sw, Int((band.hi.x + apron).rounded(.up)))
            let y1 = min(sh, Int((band.hi.y + apron).rounded(.up)))
            return (band.rows, min(x0, sw - 1), min(y0, sh - 1), max(x1, min(x0 + 1, sw)), max(y1, min(y0 + 1, sh)))
        }
        // One size for all: the largest, one pixel more where needed so the
        // origin can snap down to even, and the same parity as the sensor
        // so an even origin can still reach its far edge.
        func size(_ extent: Int, _ sensor: Int) -> Int {
            var s = min(sensor, extent + 1)
            if (sensor - s) % 2 != 0 { s = min(sensor, s + 1) }
            if (sensor - s) % 2 != 0 { s -= 1 }
            return max(1, s)
        }
        let windowWidth = size(rects.map { $0.x1 - $0.x0 }.max() ?? sw, sw)
        let windowHeight = size(rects.map { $0.y1 - $0.y0 }.max() ?? sh, sh)
        let bands = rects.map { rect -> Band in
            func origin(_ start: Int, _ window: Int, _ sensor: Int) -> Int {
                min(max(0, start & ~1), max(0, (sensor - window) & ~1))
            }
            return Band(rows: rect.rows, windowX: origin(rect.x0, windowWidth, sw),
                        windowY: origin(rect.y0, windowHeight, sh))
        }
        return (bands, windowWidth, windowHeight)
    }

    private func prepareFullResolution(_ source: Source, orientation: Orientation, lens: Lens?,
                                       into output: MTLTexture, windowPixelBudget: Int) throws {
        let plan = Self.bandPlan(orientation: orientation, lens: lens, pixelBudget: windowPixelBudget)
        let (ww, wh) = (plan.windowWidth, plan.windowHeight)
        // The window textures, made once for the frame.
        var scratch: [String: MTLTexture] = [:]
        func texture(_ format: MTLPixelFormat, _ purpose: String) throws -> MTLTexture {
            let key = "\(purpose)-\(format.rawValue)"
            if let existing = scratch[key] { return existing }
            let made = try HDRMergeKernels.makeTexture(gpu, width: ww, height: wh, format: format)
            scratch[key] = made
            return made
        }
        for band in plan.bands {
            let window: MTLTexture
            var inverse = SIMD3<Float>(repeating: 1)
            switch source {
            case .bayer(let file, let levels, let multipliers):
                guard case .bayer(let order) = file.summary.cfaPattern, let plane = file.sensorPlane,
                      let buffer = gpu.makeSharedBuffer(wrapping: plane) else { throw HDRMergeKernelError.notABayerFrame }
                let cfa = try texture(.r32Float, "cfa")
                guard let commands = gpu.commandQueue.makeCommandBuffer(),
                      let encoder = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
                let pso = try pipeline("mergePanoPrepBayerWindow")
                encoder.setComputePipelineState(pso)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                var rawWidth = UInt32(file.summary.rawWidth)
                var origin = SIMD2<UInt32>(UInt32(band.windowX), UInt32(band.windowY))
                var black = levels.channelBlack, invRange = levels.scale
                var mul = SIMD4<Float>(multipliers, 1)
                var pattern = order
                encoder.setBytes(&rawWidth, length: 4, index: 1)
                encoder.setBytes(&origin, length: 8, index: 2)
                encoder.setBytes(&black, length: 16, index: 3)
                encoder.setBytes(&invRange, length: 4, index: 4)
                encoder.setBytes(&mul, length: 16, index: 5)
                encoder.setBytes(&pattern, length: 1, index: 6)
                encoder.setTexture(cfa, index: 0)
                HDRMergeKernels.dispatch(encoder, pso: pso, width: ww, height: wh)
                encoder.endEncoding()
                window = try renderPipeline.encodeRCD(cmdBuffer: commands, cfa: cfa, order: order) { format, role in
                    try texture(format, "rcd-\(role)")
                }
                try HDRMergeKernels.run(commands)
                inverse = SIMD3(1 / max(multipliers.x, 1e-6), 1 / max(multipliers.y, 1e-6), 1 / max(multipliers.z, 1e-6))
            case .linear(let file, _):
                guard let plane = file.linearPlane, let buffer = gpu.makeSharedBuffer(wrapping: plane) else {
                    throw HDRMergeKernelError.notABayerFrame
                }
                window = try texture(.rgba16Float, "linear")
                let pso = try gpu.lazyPipeline(.linearUpload)
                guard let commands = gpu.commandQueue.makeCommandBuffer(),
                      let encoder = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
                encoder.setComputePipelineState(pso)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                var planeWidth = UInt32(file.summary.rawWidth)
                var unit = SIMD4<Float>(repeating: 1)
                var origin = SIMD2<UInt32>(UInt32(band.windowX), UInt32(band.windowY))
                encoder.setBytes(&planeWidth, length: 4, index: 1)
                encoder.setBytes(&unit, length: 16, index: 2)
                encoder.setBytes(&origin, length: 8, index: 3)
                encoder.setTexture(window, index: 0)
                HDRMergeKernels.dispatch(encoder, pso: pso, width: ww, height: wh)
                encoder.endEncoding()
                try HDRMergeKernels.run(commands)
            }
            try lensPass(source: window, sourceOrigin: SIMD2(Float(band.windowX), Float(band.windowY)),
                         orientation: orientation, span: 1, lens: lens, inverseMultipliers: inverse,
                         output: output, clipShare: nil, rows: band.rows)
        }
    }

    // MARK: - Reduced sources

    /// The whole photo reduced by `span` on the sensor's grid, before lens
    /// correction and turning: per-colour block means at unit white balance
    /// with the clipped share in alpha for a Bayer raw, box means for a
    /// linear source.
    private func reducedSource(_ source: Source, span: Int, format: MTLPixelFormat)
    throws -> (texture: MTLTexture, inverseMultipliers: SIMD3<Float>, hasClipShare: Bool) {
        let summary = source.file.summary
        let rawW = summary.rawWidth, rawH = summary.rawHeight
        // Blocks cut short at the right and bottom edges still get a texel,
        // so the lens pass's reads near those edges repeat real pixels.
        let w = (rawW + span - 1) / span, h = (rawH + span - 1) / span
        let out = try HDRMergeKernels.makeTexture(gpu, width: w, height: h, format: format)
        guard let commands = gpu.commandQueue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        switch source {
        case .bayer(let file, let levels, _):
            guard case .bayer(let order) = file.summary.cfaPattern, let plane = file.sensorPlane,
                  let buffer = gpu.makeSharedBuffer(wrapping: plane) else { throw HDRMergeKernelError.notABayerFrame }
            let pso = try gpu.lazyPipeline(.mergeHDRBinnedAnalysis)
            encoder.setComputePipelineState(pso)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            var width32 = UInt32(rawW), height32 = UInt32(rawH)
            var black = levels.channelBlack, invRange = levels.scale, clipRaw = levels.clipRaw
            var pattern = order, span32 = UInt32(span)
            encoder.setBytes(&width32, length: 4, index: 1)
            encoder.setBytes(&height32, length: 4, index: 2)
            encoder.setBytes(&black, length: 16, index: 3)
            encoder.setBytes(&invRange, length: 4, index: 4)
            encoder.setBytes(&clipRaw, length: 4, index: 5)
            encoder.setBytes(&pattern, length: 1, index: 6)
            encoder.setBytes(&span32, length: 4, index: 7)
            encoder.setTexture(out, index: 0)
            HDRMergeKernels.dispatch(encoder, pso: pso, width: w, height: h)
        case .linear(let file, _):
            guard let plane = file.linearPlane, let buffer = gpu.makeSharedBuffer(wrapping: plane) else {
                throw HDRMergeKernelError.notABayerFrame
            }
            let pso = try gpu.lazyPipeline(.linearBinned)
            encoder.setComputePipelineState(pso)
            encoder.setBuffer(buffer, offset: 0, index: 0)
            var planeWidth = UInt32(rawW), planeHeight = UInt32(rawH)
            var unit = SIMD4<Float>(repeating: 1)
            var span32 = UInt32(span)
            encoder.setBytes(&planeWidth, length: 4, index: 1)
            encoder.setBytes(&planeHeight, length: 4, index: 2)
            encoder.setBytes(&unit, length: 16, index: 3)
            encoder.setBytes(&span32, length: 4, index: 4)
            encoder.setTexture(out, index: 0)
            HDRMergeKernels.dispatch(encoder, pso: pso, width: w, height: h)
        }
        encoder.endEncoding()
        try HDRMergeKernels.run(commands)
        if case .bayer = source { return (out, SIMD3(repeating: 1), true) }
        return (out, SIMD3(repeating: 1), false)
    }

    // MARK: - The lens pass

    /// `mergePanoPrepLens`'s parameters, in the order of its struct.
    static func lensParameters(orientation: Orientation, span: Int, sourceOrigin: SIMD2<Float>, rowOffset: Int,
                               lens: Lens?, inverseMultipliers: SIMD3<Float>, carryClip: Bool) -> [Float] {
        let m = orientation.uprightToSensor
        let c = lens?.correction
        let distortion = c?.distortion?.packed ?? (type: 0, terms: SIMD3<Float>(0, 0, 0))
        let tca = c?.tca
        let vignetting = c?.vignetting
        return [
            Float(orientation.sensorWidth), Float(orientation.sensorHeight),
            Float(m.a), Float(m.b), Float(m.c), Float(m.d), Float(m.e), Float(m.f),
            Float(span),
            sourceOrigin.x, sourceOrigin.y,
            Float(rowOffset),
            c?.cropRatio ?? 1,
            Float(distortion.type), distortion.terms.x, distortion.terms.y, distortion.terms.z,
            tca == nil ? 0 : 1, tca?.red.x ?? 0, tca?.red.y ?? 0, tca?.red.z ?? 1,
            tca?.blue.x ?? 0, tca?.blue.y ?? 0, tca?.blue.z ?? 1,
            vignetting == nil ? 0 : 1, vignetting?.k1 ?? 0, vignetting?.k2 ?? 0, vignetting?.k3 ?? 0,
            inverseMultipliers.x, inverseMultipliers.y, inverseMultipliers.z,
            carryClip ? 1 : 0,
        ]
    }

    /// Writes `rows` of `output` from `source`, in bands of rows, one
    /// command buffer each. `sourceOrigin` is the source's texel (0, 0) in
    /// texels from the sensor's corner.
    private func lensPass(source: MTLTexture, sourceOrigin: SIMD2<Float>, orientation: Orientation, span: Int,
                          lens: Lens?, inverseMultipliers: SIMD3<Float>, output: MTLTexture, clipShare: MTLTexture?,
                          rows: Range<Int>) throws {
        let pso = try pipeline("mergePanoPrepLens")
        let rowsPerBand = max(1, Self.passBandPixels / max(output.width, 1))
        var y = rows.lowerBound
        while y < rows.upperBound {
            let bandRows = min(rowsPerBand, rows.upperBound - y)
            guard let commands = gpu.commandQueue.makeCommandBuffer(),
                  let encoder = commands.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
            encoder.setComputePipelineState(pso)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(output, index: 1)
            // An unused slot still needs a texture bound.
            encoder.setTexture(clipShare ?? output, index: 2)
            var parameters = Self.lensParameters(orientation: orientation, span: span, sourceOrigin: sourceOrigin,
                                                 rowOffset: y, lens: lens, inverseMultipliers: inverseMultipliers,
                                                 carryClip: clipShare != nil)
            encoder.setBytes(&parameters, length: parameters.count * MemoryLayout<Float>.size, index: 0)
            HDRMergeKernels.dispatch(encoder, pso: pso, width: output.width, height: bandRows)
            encoder.endEncoding()
            try HDRMergeKernels.run(commands)
            y += bandRows
        }
    }

    /// This object's pipeline for the kernel `name`, built on first use.
    private func pipeline(_ name: String) throws -> MTLComputePipelineState {
        try pipelines.withLock { built in
            if let existing = built[name] { return existing }
            guard let function = gpu.library.makeFunction(name: name) else {
                throw GPUContextError.missingShaderFunction(name)
            }
            let made = try gpu.device.makeComputePipelineState(function: function)
            built[name] = made
            return made
        }
    }
}
