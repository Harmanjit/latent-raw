import CoreGraphics
import Foundation
import ImageIO
import PixelEngine
import RawCore
import UniformTypeIdentifiers
import simd

/// A quick, low-resolution stitch made from the thumbnails, to check a
/// layout by eye: are the seams roughly aligned, the horizon level, every
/// photo in its place? Not the final blend: each canvas pixel is a plain
/// weighted average of the photos covering it, each photo fading out
/// towards its edges (feathering), so misalignment shows as doubled edges
/// instead of being hidden by seams.
public enum PanoramaPreview {
    /// Camera RGB at unit white balance with coverage in alpha, four
    /// Float32 per pixel, row by row.
    public struct Image: Sendable {
        public let width: Int
        public let height: Int
        /// Output pixels per canvas pixel.
        public let scale: Double
        public let rgba: [Float]
    }

    /// The layout stitched at `longSide` pixels on its long side (never
    /// larger than the thumbnails can fill).
    ///
    /// - Parameter outlineCrop: draw the Auto Crop rectangle as a thin
    ///   bright line.
    public static func stitch(_ layout: PanoramaLayout, thumbnails: [Int: PanoramaThumbnail], longSide: Int,
                              outlineCrop: Bool = true) -> Image {
        let canvas = layout.canvas
        let scale = min(Double(longSide) / Double(max(canvas.width, canvas.height)), 1)
        let width = max(1, Int(Double(canvas.width) * scale)), height = max(1, Int(Double(canvas.height) * scale))
        let cameras = layout.cameras
        let reach = cameras.map { camera -> (axis: SIMD3<Double>, cosine: Double) in
            let halfDiagonal = (Double(camera.width * camera.width + camera.height * camera.height)).squareRoot() / 2
            return (camera.rotationMatrix * SIMD3(0, 0, 1),
                    cos(min(atan(halfDiagonal / camera.focalLengthPixels) + 0.01, .pi / 2)))
        }
        var rgba = [Float](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBufferPointer { buffer in
            let out = buffer.baseAddress!
            let bands = AlignmentSampling.bandCount(rows: height)
            AlignmentSampling.parallel(bands) { band in
                for y in (band * height / bands)..<((band + 1) * height / bands) {
                    for x in 0..<width {
                        let p = SIMD2((Double(x) + 0.5) / scale, (Double(y) + 0.5) / scale)
                        guard let d = PanoramaMath.direction(canvasPixel: p, canvas: canvas) else { continue }
                        var sum = SIMD3<Double>.zero, total = 0.0
                        for (k, camera) in cameras.enumerated() where simd_dot(d, reach[k].axis) >= reach[k].cosine {
                            guard let t = thumbnails[camera.frameIndex],
                                  let q = PanoramaMath.framePixel(direction: d, camera: camera),
                                  q.x >= 0, q.y >= 0, q.x < Double(camera.width), q.y < Double(camera.height),
                                  let sample = bilinear(t, q) else { continue }
                            let edge = min(q.x, Double(camera.width) - q.x, q.y, Double(camera.height) - q.y)
                            let feather = min(max(edge / (0.5 * Double(min(camera.width, camera.height))), 1e-3), 1)
                            let w = feather * Double(sample.w)
                            sum += w * camera.exposureGain * SIMD3(Double(sample.x), Double(sample.y), Double(sample.z))
                            total += w
                        }
                        guard total > 0 else { continue }
                        let i = 4 * (y * width + x)
                        out[i] = Float(sum.x / total); out[i + 1] = Float(sum.y / total)
                        out[i + 2] = Float(sum.z / total); out[i + 3] = 1
                    }
                }
            }
        }
        if outlineCrop, layout.autoCropRect.width > 0 {
            let r = layout.autoCropRect
            let x0 = Int(r.minX * scale), x1 = min(width - 1, Int(r.maxX * scale))
            let y0 = Int(r.minY * scale), y1 = min(height - 1, Int(r.maxY * scale))
            func mark(_ x: Int, _ y: Int) {
                guard x >= 0, y >= 0, x < width, y < height else { return }
                let i = 4 * (y * width + x)
                rgba[i] = 0; rgba[i + 1] = 2; rgba[i + 2] = 2; rgba[i + 3] = 1
            }
            for x in x0...max(x0, x1) { mark(x, y0); mark(x, y0 + 1); mark(x, y1); mark(x, y1 - 1) }
            for y in y0...max(y0, y1) { mark(x0, y); mark(x0 + 1, y); mark(x1, y); mark(x1 - 1, y) }
        }
        return Image(width: width, height: height, scale: scale, rgba: rgba)
    }

    /// RGBA of `t` at full-resolution point `q`, edges repeated.
    static func bilinear(_ t: PanoramaThumbnail, _ q: SIMD2<Double>) -> SIMD4<Float>? {
        let x = q.x / Double(t.span) - 0.5, y = q.y / Double(t.span) - 0.5
        let ix = Int(x.rounded(.down)), iy = Int(y.rounded(.down))
        let fx = Float(x - Double(ix)), fy = Float(y - Double(iy))
        let x0 = min(max(ix, 0), t.width - 1), x1 = min(max(ix + 1, 0), t.width - 1)
        let y0 = min(max(iy, 0), t.height - 1), y1 = min(max(iy + 1, 0), t.height - 1)
        func texel(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let i = 4 * (y * t.width + x)
            return SIMD4(t.rgba[i], t.rgba[i + 1], t.rgba[i + 2], t.rgba[i + 3])
        }
        let value = (1 - fx) * (1 - fy) * texel(x0, y0) + fx * (1 - fy) * texel(x1, y0)
            + (1 - fx) * fy * texel(x0, y1) + fx * fy * texel(x1, y1)
        return value.w > 0 ? value : nil
    }

    /// The stitch rendered the way Latent would show it: opened as a linear
    /// source with `reference`'s colour (its white balance and matrix) and
    /// rendered through the pipeline with default settings, lens
    /// correction off (it is in the pixels already). Upright, as stitched.
    public static func render(_ image: Image, reference: RawSummary, cameraToXYZ: [Float]?,
                              gpu: GPUContext) throws -> CGImage {
        let info = LinearMergeInfo(kind: MergeRecipe.Kind.panorama.rawValue, clipLevel: 1, lensApplied: true,
                                   baselineShift: 0)
        guard let file = RawFile.linearSource(
            width: image.width, height: image.height, like: reference, cameraToXYZ: cameraToXYZ,
            baselineExposure: 0, mergeInfo: info,
            fill: { plane in
                for i in 0..<(image.width * image.height * 4) {
                    plane[i] = Float16(min(max(image.rgba[i], 0), LinearPlane.maximumValue))
                }
            })
        else { throw RenderError.gpuBufferAllocationFailed }
        let session = try ImageSession(file: file, gpu: gpu)
        let parameters = try ExportPlan.parameters(editStackJSON: nil, session: session, colorSpace: .sRGB)
        let rendered = try RenderPipeline(gpu: gpu).render(session, scale: .full, parameters: parameters)
        return try Exporter(gpu: gpu).cgImage(from: rendered, colorSpace: .sRGB)
    }

    /// Writes `image` as a JPEG.
    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.9) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
