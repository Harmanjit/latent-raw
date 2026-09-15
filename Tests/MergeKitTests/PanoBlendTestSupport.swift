import CoreGraphics
import Foundation
import ImageIO
import PixelEngine
import UniformTypeIdentifiers
import XCTest
import simd
@testable import MergeKit

/// What the panorama stitcher's tests share: an analytic scene painted on
/// the sphere of directions, photos of it taken by known cameras, layouts
/// around them, and a stitch assembled into one image.
enum PanoBlendTestSupport {
    // MARK: - The scene

    /// Linear camera RGB seen in direction `d` (any length): smooth colour
    /// gradients, stripes and a checkerboard with soft edges `edge` radians
    /// wide, and a few round spots. Values stay within 0.02 ... 0.95.
    static func radiance(_ d: SIMD3<Double>, edge: Double) -> SIMD3<Double> {
        let horizontal = (d.x * d.x + d.z * d.z).squareRoot()
        let theta = atan2(d.x, d.z), phi = atan2(-d.y, horizontal)
        func soft(_ t: Double) -> Double { 0.5 + 0.5 * tanh(t / edge) }
        var rgb = SIMD3<Double>(0.10 + 0.08 * (1 + sin(1.3 * theta)) * (0.7 + 0.3 * cos(2 * phi)),
                                0.12 + 0.06 * cos(0.7 * theta + phi),
                                0.08 + 0.10 * (0.5 + 0.5 * sin(3 * phi + 0.4)))
        // Vertical stripes 0.08 rad apart (sin(39θ) / 39 is about the angle to
        // the nearest edge), their edges soft.
        let stripe = soft(sin(theta * 39) / 39)
        rgb += SIMD3(0.25, 0.18, 0.05) * stripe * soft(phi - 0.05)
        // A checkerboard below the horizon.
        let checker = soft(sin(theta * 25) * sin(phi * 25) / 25)
        rgb += SIMD3(0.05, 0.2, 0.3) * checker * soft(-phi - 0.02)
        // Round spots.
        for (centreTheta, centrePhi, radius, colour) in [(0.3, 0.1, 0.05, SIMD3(0.5, 0.1, 0.1)),
                                                          (-0.7, -0.08, 0.07, SIMD3(0.1, 0.4, 0.2)),
                                                          (1.1, 0.02, 0.04, SIMD3(0.3, 0.3, 0.5))] {
            let distance = ((theta - centreTheta) * (theta - centreTheta) + (phi - centrePhi) * (phi - centrePhi))
                .squareRoot()
            rgb += colour * soft(radius - distance)
        }
        return simd_clamp(rgb, SIMD3(repeating: 0.02), SIMD3(repeating: 0.95))
    }

    // MARK: - Cameras

    /// Camera-to-world rotation for a camera turned `yaw` right, `pitch` up
    /// and rolled `roll` clockwise, row-major.
    static func rotation(yaw: Double, pitch: Double = 0, roll: Double = 0) -> [Double] {
        let cy = cos(yaw), sy = sin(yaw), cp = cos(pitch), sp = sin(pitch), cr = cos(roll), sr = sin(roll)
        let yawMatrix = simd_double3x3(rows: [SIMD3(cy, 0, sy), SIMD3(0, 1, 0), SIMD3(-sy, 0, cy)])
        // +y is down, so looking up turns +z towards -y.
        let pitchMatrix = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cp, -sp), SIMD3(0, sp, cp)])
        let rollMatrix = simd_double3x3(rows: [SIMD3(cr, -sr, 0), SIMD3(sr, cr, 0), SIMD3(0, 0, 1)])
        let m = yawMatrix * pitchMatrix * rollMatrix
        return (0..<3).flatMap { row in (0..<3).map { column in m[column][row] } }
    }

    struct Shot {
        var yaw: Double
        var pitch = 0.0
        var roll = 0.0
        /// The photo's brightness relative to the scene; its gain undoes it.
        var exposure = 1.0
    }

    /// Cameras for `shots`, all `width x height` full-resolution pixels
    /// with focal length `focal`. `gainError` multiplies every other gain,
    /// to leave exposure differences for the blend to hide.
    static func cameras(_ shots: [Shot], width: Int, height: Int, focal: Double, gainError: Double = 1)
        -> [PanoramaCamera] {
        shots.enumerated().map { index, shot in
            PanoramaCamera(frameIndex: index, rotation: rotation(yaw: shot.yaw, pitch: shot.pitch, roll: shot.roll),
                           focalLengthPixels: focal, principalPoint: SIMD2(Double(width) / 2, Double(height) / 2),
                           width: width, height: height,
                           exposureGain: (1 / shot.exposure) * (index % 2 == 1 ? gainError : 1))
        }
    }

    /// A layout whose canvas just holds every camera's photo, and the output
    /// size at `scale` (with the decode span the sizing rule would pick).
    static func layout(_ cameras: [PanoramaCamera], projection: PanoramaProjection, pixelsPerRadian: Double,
                       scale: Double) -> (PanoramaLayout, PanoramaOutputSize) {
        var lower = SIMD2<Double>(repeating: .infinity), upper = SIMD2<Double>(repeating: -.infinity)
        let probe = PanoramaCanvas(projection: projection, pixelsPerRadian: pixelsPerRadian, origin: .zero,
                                   width: 1, height: 1)
        for camera in cameras {
            for i in 0...40 {
                for j in 0...40 where i == 0 || j == 0 || i == 40 || j == 40 {
                    let p = SIMD2(Double(camera.width) * Double(i) / 40, Double(camera.height) * Double(j) / 40)
                    let d = PanoramaMath.direction(framePixel: p, camera: camera)
                    guard let c = PanoramaMath.canvasPixel(direction: d, canvas: probe) else { continue }
                    lower = simd_min(lower, c)
                    upper = simd_max(upper, c)
                }
            }
        }
        let width = Int(ceil(upper.x - lower.x)), height = Int(ceil(upper.y - lower.y))
        let canvas = PanoramaCanvas(projection: projection, pixelsPerRadian: pixelsPerRadian, origin: lower,
                                    width: width, height: height)
        let layout = PanoramaLayout(cameras: cameras, canvas: canvas, autoCropRect: .zero)
        var span = 1
        while scale <= 0.5, 1 / Double(span + 1) >= scale { span += 1 }
        let output = PanoramaOutputSize(fullWidth: width, fullHeight: height, scale: scale,
                                        width: Int(Double(width) * scale), height: Int(Double(height) * scale),
                                        limit: scale < 1 ? .memory : .none, decodeSpan: span)
        return (layout, output)
    }

    // MARK: - Photos

    /// The exposure `shots[i].exposure` of each camera's photo, rendered at
    /// `sampleScale` into `store`. Alpha is 1 inside a slightly curved
    /// outline (like a lens-corrected photo's), soft over a pixel, and 0
    /// outside, where the colour is a bright 3.0 that must never show.
    static func render(_ cameras: [PanoramaCamera], shots: [Shot], sampleScale: Double, edge: Double,
                       into store: PanoramaFrameStore) throws {
        for (index, camera) in cameras.enumerated() {
            let width = Int((Double(camera.width) * sampleScale).rounded())
            let height = Int((Double(camera.height) * sampleScale).rounded())
            let exposure = shots[index].exposure
            try store.add(frameIndex: camera.frameIndex, width: width, height: height, sampleScale: sampleScale) { pixels in
                let base = UnsafeSendablePointer(pixels.baseAddress!)
                DispatchQueue.concurrentPerform(iterations: height) { row in
                    for column in 0..<width {
                        let p = SIMD2((Double(column) + 0.5) / sampleScale, (Double(row) + 0.5) / sampleScale)
                        let n = SIMD2(2 * p.x / Double(camera.width) - 1, 2 * p.y / Double(camera.height) - 1)
                        // Distance inside the curved outline, in prepared pixels.
                        let insideX = (1 - 0.04 * n.y * n.y - abs(n.x)) * Double(width) / 2
                        let insideY = (1 - 0.04 * n.x * n.x - abs(n.y)) * Double(height) / 2
                        let alpha = min(max(insideX + 0.5, 0), 1) * min(max(insideY + 0.5, 0), 1)
                        let i = (row * width + column) * 4
                        if alpha <= 0 {
                            base.pointer[i] = 3; base.pointer[i + 1] = 3; base.pointer[i + 2] = 3; base.pointer[i + 3] = 0
                            continue
                        }
                        let rgb = radiance(PanoramaMath.direction(framePixel: p, camera: camera), edge: edge) * exposure
                        base.pointer[i] = Float16(rgb.x); base.pointer[i + 1] = Float16(rgb.y)
                        base.pointer[i + 2] = Float16(rgb.z); base.pointer[i + 3] = Float16(alpha)
                    }
                }
            }
        }
    }

    /// The scene as the output should show it: the radiance at each output
    /// pixel's centre, row by row.
    static func truth(_ layout: PanoramaLayout, _ output: PanoramaOutputSize, edge: Double,
                      x: Int, y: Int) -> SIMD3<Double> {
        let canvasPixel = (SIMD2(Double(x), Double(y)) + 0.5) / output.scale
        let d = PanoramaMath.direction(canvasPixel: canvasPixel, canvas: layout.canvas)!
        return radiance(d, edge: edge)
    }

    struct UnsafeSendablePointer: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<Float16>
        init(_ pointer: UnsafeMutablePointer<Float16>) { self.pointer = pointer }
    }

    // MARK: - Stitching

    struct Stitched {
        let width: Int
        let height: Int
        /// rgba per pixel, row by row.
        let rgba: [Float]
        let plan: PanoramaBlendPlan
        let seams: PanoramaSeamMap
        let statistics: PanoramaBlendStatistics

        func pixel(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let i = (y * width + x) * 4
            return SIMD4(rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3])
        }

        /// A rectangle of the kind Auto Crop keeps: the middle 80% of the
        /// width, trimmed vertically until every pixel in it is covered.
        /// (The real Auto Crop finds the largest such rectangle; this is
        /// enough for tests, which only need somewhere no photo's outer
        /// edge reaches.)
        var innerRectangle: PixelRegion {
            let left = width / 10, right = width - width / 10
            var top = 0, bottom = height - 1
            for x in left..<right {
                var first = 0, last = height - 1
                while first < height, rgba[(first * width + x) * 4 + 3] < 0.999 { first += 1 }
                while last > first, rgba[(last * width + x) * 4 + 3] < 0.999 { last -= 1 }
                top = max(top, first)
                bottom = min(bottom, last)
            }
            return PixelRegion(x: left, y: top, width: right - left, height: max(0, bottom - top + 1))
        }

        func label(_ x: Int, _ y: Int) -> Int {
            Int(seams.labels[(y / seams.step) * seams.width + x / seams.step])
        }
    }

    /// Stitches with `options` and assembles the tiles, checking they come
    /// in reading order and cover the output exactly once.
    static func stitch(_ layout: PanoramaLayout, _ output: PanoramaOutputSize, frames: PanoramaBlendFrameSource,
                       options: PanoramaBlendOptions, gpu: GPUContext) throws -> Stitched {
        let stitcher = try PanoramaStitcher(layout: layout, outputSize: output, frames: frames, options: options,
                                            gpu: gpu)
        var rgba = [Float](repeating: -1, count: output.width * output.height * 4)
        var expected = (x: 0, y: 0)
        try stitcher.stitch { tile in
            XCTAssertEqual(tile.region.x, expected.x)
            XCTAssertEqual(tile.region.y, expected.y)
            for row in 0..<tile.region.height {
                for column in 0..<tile.region.width {
                    let source = (row * tile.region.width + column) * 4
                    let target = ((tile.region.y + row) * output.width + tile.region.x + column) * 4
                    for c in 0..<4 { rgba[target + c] = Float(tile.pixels[source + c]) }
                }
            }
            expected.x = tile.region.x + tile.region.width
            if expected.x >= output.width { expected = (0, tile.region.y + tile.region.height) }
        }
        return Stitched(width: output.width, height: output.height, rgba: rgba, plan: try XCTUnwrap(stitcher.plan),
                        seams: try XCTUnwrap(stitcher.seamMap), statistics: stitcher.statistics)
    }

    // MARK: - Standard scenes

    /// A single row of five landscape photos on a Cylindrical canvas, 45%
    /// overlap, with a little pitch and roll, at 0.7 to 1.4 times the
    /// scene's brightness (gains undo it), decoded at half size and output at
    /// 0.45 of full resolution.
    struct Row {
        let shots: [Shot]
        let cameras: [PanoramaCamera]
        let layout: PanoramaLayout
        let output: PanoramaOutputSize
        let sampleScale: Double
        let edge: Double
    }

    static func row(projection: PanoramaProjection = .cylindrical, gainError: Double = 1, scale: Double = 0.45,
                    sampleScale: Double = 0.5) -> Row {
        let focal = 700.0
        let shots = [Shot(yaw: -1.08, pitch: 0.02, roll: 0.01, exposure: 1),
                     Shot(yaw: -0.54, pitch: -0.03, roll: -0.02, exposure: 0.7),
                     Shot(yaw: 0, pitch: 0.01, roll: 0.015, exposure: 1.4),
                     Shot(yaw: 0.54, pitch: 0.03, roll: 0, exposure: 0.85),
                     Shot(yaw: 1.08, pitch: -0.01, roll: -0.01, exposure: 1.2)]
        let cameras = cameras(shots, width: 800, height: 600, focal: focal, gainError: gainError)
        let (layout, output) = layout(cameras, projection: projection, pixelsPerRadian: focal, scale: scale)
        // Edges two output pixels wide.
        return Row(shots: shots, cameras: cameras, layout: layout, output: output, sampleScale: sampleScale,
                   edge: 2 / (focal * scale))
    }

    static func store(for row: Row) throws -> PanoramaFrameStore {
        let store = try PanoramaFrameStore(parent: scratchParent())
        try render(row.cameras, shots: row.shots, sampleScale: row.sampleScale, edge: row.edge, into: store)
        return store
    }

    /// The tests' own scratch folder, so they never touch the app's.
    static func scratchParent() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MergeKitTests-Panorama", isDirectory: true)
    }

    // MARK: - Review images

    /// Writes a JPEG of part of `stitched`, magnified `zoom` times (nearest
    /// neighbour, so nothing hides), for looking at a seam closely.
    @discardableResult
    static func writeReviewCrop(_ stitched: Stitched, name: String, crop: PixelRegion, zoom: Int,
                                seams: Bool = false) throws -> URL? {
        var rgba = [Float](repeating: 0, count: crop.width * zoom * crop.height * zoom * 4)
        for y in 0..<(crop.height * zoom) {
            for x in 0..<(crop.width * zoom) {
                let p = stitched.pixel(min(crop.x + x / zoom, stitched.width - 1),
                                       min(crop.y + y / zoom, stitched.height - 1))
                for c in 0..<4 { rgba[(y * crop.width * zoom + x) * 4 + c] = p[c] }
            }
        }
        let magnified = Stitched(width: crop.width * zoom, height: crop.height * zoom, rgba: rgba, plan: stitched.plan,
                                 seams: stitched.seams, statistics: stitched.statistics)
        return try writeReview(magnified, name: name, seams: seams)
    }

    /// Writes a JPEG of `stitched` (gamma-encoded, uncovered pixels in a
    /// grey checkerboard, seam boundaries in red if `seams`) into
    /// LATENT_REVIEW_DIR, when that is set. Returns the file, if written.
    @discardableResult
    static func writeReview(_ stitched: Stitched, name: String, seams: Bool, exposure: Float = 1.6) throws -> URL? {
        guard let folder = ProcessInfo.processInfo.environment["LATENT_REVIEW_DIR"] else { return nil }
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let w = stitched.width, h = stitched.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let p = stitched.pixel(x, y)
                var rgb = SIMD3<Float>(p.x, p.y, p.z) * exposure
                rgb = SIMD3(pow(min(max(rgb.x, 0), 1), 1 / 2.2), pow(min(max(rgb.y, 0), 1), 1 / 2.2),
                            pow(min(max(rgb.z, 0), 1), 1 / 2.2))
                let checker: Float = ((x / 8 + y / 8) % 2 == 0) ? 0.35 : 0.5
                rgb = rgb * p.w + SIMD3(repeating: checker) * (1 - p.w)
                if seams, p.w > 0 {
                    let label = stitched.label(x, y)
                    let right = x + 1 < w ? stitched.label(x + 1, y) : label
                    let below = y + 1 < h ? stitched.label(x, y + 1) : label
                    if label != right || label != below { rgb = SIMD3(1, 0, 0) }
                }
                let i = (y * w + x) * 4
                bytes[i] = UInt8(rgb.x * 255); bytes[i + 1] = UInt8(rgb.y * 255); bytes[i + 2] = UInt8(rgb.z * 255)
                bytes[i + 3] = 255
            }
        }
        let url = directory.appendingPathComponent(name + ".jpg")
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
