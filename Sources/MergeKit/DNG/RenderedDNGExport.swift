// DNG export (Render to DNG): one photo, its scene-referred edit baked in,
// written with the merge's LinearRaw writer.

import CoreGraphics
import Foundation
import Metal
import RawCore
import ColorKit
import PixelEngine
import simd

/// Writes a photo rendered into scene-linear Rec. 2020 light
/// (`ExportWorker.renderSceneLinear`) as a LinearRaw DNG, which Latent,
/// Apple's RAW engine and other raw converters open like a camera raw.
///
/// **Colour.** The DNG keeps the original camera's name and colour matrix,
/// because that is what raw readers go by (LibRaw, which Latent reads
/// with, takes a camera's matrix from its own table by make and model).
/// So the rendered light is turned back into that camera's native RGB,
/// through the inverse of the very matrix Latent opens the file with
/// (`CameraColorProfile.cameraToWorking`, whose rows are normalised so
/// white stays (1, 1, 1)). The pixels are already white-balanced, so the
/// as-shot neutral is grey, (1, 1, 1): a reader's "As Shot" white balance
/// is the one the edit chose. A saturated colour that falls outside what
/// the camera's primaries can hold is cut at zero, as a raw can't store
/// negative light.
///
/// The camera, lens and exposure tags are the original's, so the DNG still
/// says what took it. The pixels are upright, so the orientation is 1.
///
/// A `latent:Merge` recipe of kind `rendered` names the original and says
/// the lens corrections are already in the pixels, so Latent doesn't apply
/// them twice; its clip level sits above every pixel, because highlight
/// recovery has already been done.
public enum RenderedDNGExport {
    /// Linear Rec. 2020 to the camera's native RGB: the inverse of the
    /// matrix Latent opens the camera's files with. Nil when the matrix
    /// can't be used.
    public static func workingToCamera(cameraToXYZ: [Float]) -> simd_float3x3? {
        ColorKit.CameraColorProfile(cameraToXYZRowMajor: cameraToXYZ)?.cameraToWorking.inverse
    }

    /// The tags for a rendered DNG of the photo `summary` describes.
    public static func metadata(summary s: RawSummary, cameraToXYZ: [Float], lensModel: String?,
                                softwareVersion: String) throws -> MergeDNGMetadata {
        let lens = s.lens
        let lensMake = lens.make.trimmingCharacters(in: .whitespaces)
        return MergeDNGMetadata(
            make: s.cameraMake, model: s.cameraModel,
            colorMatrix1: try MergeDNGMetadata.colorMatrix(fromCamXYZ: cameraToXYZ),
            asShotNeutral: [1, 1, 1], baselineExposure: 0, orientation: 1,
            software: MergeDNGMetadata.software(version: softwareVersion),
            captureDate: s.captureTime.timeIntervalSince1970 > 0 ? s.captureTime : nil,
            exposureTime: s.shutter > 0 ? s.shutter : nil,
            fNumber: s.aperture > 0 ? s.aperture : nil,
            iso: s.iso > 0 ? s.iso : nil,
            focalLength: s.focalLength > 0 ? s.focalLength : nil,
            lensMake: lensMake.isEmpty ? nil : lensMake,
            lensModel: lensModel ?? MergeDNGMetadata.lensName(model: s.lensModel, identity: lens),
            lensSpecification: MergeDNGMetadata.lensSpecification(for: lens),
            lens: LinearMergeInfo.Lens(summary: s))
    }

    /// The recipe written into the DNG: `source` is the original.
    /// `look` names a full look baked in (`options["look"]`), so the
    /// recipe says the pixels are display-referred underneath.
    public static func recipe(source: MergeRecipe.Source, maximum: Float, look: BakedLook? = nil) -> MergeRecipe {
        // Above every stored value, so nothing counts as clipped: the
        // render reconstructed the highlights already.
        MergeRecipe(kind: .rendered, clipLevel: max(maximum, 1) * 2, lensApplied: true, reference: 0,
                    options: look == nil ? [:] : ["look": .string("baked")], sources: [source])
    }

    /// A full look baked into a rendered DNG ("DNG, full look baked in").
    ///
    /// A raw file holds scene light, and whatever opens it applies its own
    /// tone curve. To keep the edit's look, the render's display-referred
    /// light (tone curve, grading and the rest applied, SDR white at 1) is
    /// passed through the inverse of the default tone curve, Latent's
    /// Naka-Rushton sigmoid at `contrast` and `greyPoint` (ColorPipeline
    /// .metal, `toneMapSigmoid` with no headroom). Latent opening the DNG
    /// with its default look then turns the pixels back into the edit's
    /// display values. Other raw converters apply curves of their own, so
    /// there the file opens close to, not exactly as, the edit.
    public struct BakedLook: Sendable, Equatable {
        public var contrast: Float
        public var greyPoint: Float
        public init(contrast: Float, greyPoint: Float) { self.contrast = contrast; self.greyPoint = greyPoint }

        /// Display values at and above this are held here: the sigmoid
        /// reaches 1 only at infinite light. About seven stops above grey
        /// at the default contrast, within a half float's range.
        static let ceiling: Float = 0.9995

        /// The scene value the sigmoid y = x^c / (x^c + k^c) takes to `y`.
        public func sceneValue(display y: Float) -> Float {
            let held = min(max(y, 0), Self.ceiling)
            guard held > 0 else { return 0 }
            return max(greyPoint, 1e-6) * pow(held / (1 - held), 1 / max(contrast, 1e-3))
        }
    }

    /// Writes the DNG. `texture` is rgba16Float, linear Rec. 2020, with
    /// every GPU write to it finished; `cameraToXYZ` is the original raw's
    /// matrix (`RawFile.cameraToXYZMatrixRaw`). `replacingExisting` false
    /// throws `SafeFileWriter.DestinationExists` when a file took the name.
    @discardableResult
    public static func write(texture: MTLTexture, commandQueue: MTLCommandQueue, summary: RawSummary,
                             cameraToXYZ: [Float]?, lensModel: String?, preview: CGImage,
                             source: MergeRecipe.Source, softwareVersion: String, to url: URL,
                             replacingExisting: Bool, look: BakedLook? = nil) throws -> MergeDNGWriteResult {
        guard let cameraToXYZ, let toCamera = workingToCamera(cameraToXYZ: cameraToXYZ) else {
            throw MergeDNGError.invalidMetadata("the photo's camera has no colour matrix, so a DNG can't describe it")
        }
        var workingMaximum = try ExposureNormalisation.maximum(of: texture, commandQueue: commandQueue)
        // The inverse curve rises with the light, so it takes the largest
        // value to the largest.
        if let look { workingMaximum = look.sceneValue(display: workingMaximum) }
        // A bound on the largest camera value: no row of the matrix can
        // take a pixel further than the sum of its weights' sizes.
        let rowWeight = (0..<3).map { row in (0..<3).reduce(Float(0)) { $0 + abs(toCamera[$1][row]) } }.max() ?? 1
        let maximum = max(workingMaximum * rowWeight, 1e-3)
        let streamed = try LinearRawPixelSource.texture(texture, commandQueue: commandQueue)
        let pixels = LinearRawPixelSource(width: streamed.width, height: streamed.height) { region, rgb in
            try streamed.fill(region, rgb)
            if let look { undoTone(rgb, look: look) }
            toCameraSpace(rgb, matrix: toCamera)
        }
        let writer = LinearRawDNGWriter()
        return try writer.write(pixels, maximum: maximum,
                                metadata: metadata(summary: summary, cameraToXYZ: cameraToXYZ, lensModel: lensModel,
                                                   softwareVersion: softwareVersion),
                                recipe: recipe(source: source, maximum: maximum, look: look), preview: preview, to: url,
                                replacingExisting: replacingExisting)
    }

    /// RGB half floats taken back through the default tone curve in place
    /// (`BakedLook.sceneValue`), channel by channel as the curve works.
    static func undoTone(_ rgb: UnsafeMutableBufferPointer<Float16>, look: BakedLook) {
        for i in rgb.indices { rgb[i] = Float16(look.sceneValue(display: Float(rgb[i]))) }
    }

    /// RGB half floats turned through `matrix` in place, negatives cut to 0.
    static func toCameraSpace(_ rgb: UnsafeMutableBufferPointer<Float16>, matrix: simd_float3x3) {
        var i = 0
        while i + 2 < rgb.count {
            let c = matrix * SIMD3<Float>(Float(rgb[i]), Float(rgb[i + 1]), Float(rgb[i + 2]))
            rgb[i] = Float16(max(c.x, 0)); rgb[i + 1] = Float16(max(c.y, 0)); rgb[i + 2] = Float16(max(c.z, 0))
            i += 3
        }
    }

    /// The original's path as the recipe records it: relative to the
    /// DNG's folder when they share a volume path prefix, else its name.
    public static func relativePath(of original: URL, from folder: URL) -> String {
        let from = folder.standardizedFileURL.pathComponents
        let to = original.standardizedFileURL.pathComponents
        var common = 0
        while common < min(from.count, to.count), from[common] == to[common] { common += 1 }
        guard common > 1 else { return original.lastPathComponent }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + to[common...]).joined(separator: "/")
    }
}
