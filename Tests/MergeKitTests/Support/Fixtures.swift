import CoreGraphics
import Foundation
@testable import MergeKit

/// Shared inputs: a D750-like reference frame (the spike's numbers), a
/// recipe, a preview image and synthetic pixels.
enum Fixtures {
    /// Nikon D750 ColorMatrix (LibRaw's cam_xyz for it).
    static let d750CamXYZ: [Float] = [0.9020, -0.2890, -0.0715, -0.4535, 1.2436, 0.2348, -0.0934, 0.1919, 0.7086]
    /// D750 daylight-ish as-shot multipliers.
    static let d750Multipliers: [Float] = [2.078125, 1, 1.207031]

    static let captureDate = Date(timeIntervalSince1970: 1_789_498_800)
    static let utc = TimeZone(identifier: "UTC")!

    static func metadata(baselineExposure: Double = -1.5) throws -> MergeDNGMetadata {
        MergeDNGMetadata(
            make: "Nikon", model: "D750",
            colorMatrix1: try MergeDNGMetadata.colorMatrix(fromCamXYZ: d750CamXYZ),
            asShotNeutral: try MergeDNGMetadata.asShotNeutral(fromCameraMultipliers: d750Multipliers),
            baselineExposure: baselineExposure, orientation: 6, software: "Latent 0.9",
            modificationDate: Date(timeIntervalSince1970: 1_789_500_000), captureDate: captureDate, timeZone: utc,
            exposureTime: 1.0 / 250, fNumber: 8, iso: 100, focalLength: 35,
            lensMake: "Nikon", lensModel: "AF-S NIKKOR 24-70mm f/2.8E ED VR",
            lensSpecification: .init(minFocalLength: 24, maxFocalLength: 70,
                                     maxApertureAtMinFocal: 2.8, maxApertureAtMaxFocal: 2.8))
    }

    static func recipe(clipLevel: Float = 8) -> MergeRecipe {
        MergeRecipe(kind: .hdr, clipLevel: clipLevel, lensApplied: false, reference: 1,
                    options: ["deghost": .string("low"), "autoAlign": .bool(true), "evSpacing": .number(2)],
                    sources: [
                        .init(path: "DSC_0106.NEF", hash: "9f86d081884c7d65", captureTime: 1_789_498_799),
                        .init(path: "DSC_0107.NEF", hash: "2c26b46b68ffc68f", captureTime: 1_789_498_800),
                        .init(path: "DSC_0108.NEF", hash: "fcde2b2edba56bf4", captureTime: 1_789_498_801),
                    ])
    }

    /// An opaque sRGB gradient, standing in for a rendered merge.
    static func previewImage(width: Int = 400, height: Int = 300) -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for y in 0..<height {
            for x in stride(from: 0, to: width, by: 8) {
                context.setFillColor(red: CGFloat(x) / CGFloat(width), green: CGFloat(y) / CGFloat(height),
                                     blue: 0.5, alpha: 1)
                context.fill(CGRect(x: x, y: y, width: 8, height: 1))
            }
        }
        return context.makeImage()!
    }

    /// Distinct, deterministic RGB values reaching exactly `maximum`, so a
    /// misplaced tile, row or channel shows up as a wrong value.
    static func pixels(width: Int, height: Int, maximum: Float) -> [Float16] {
        var out = [Float16](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 3
                out[i] = Float16(Float(x % 509) / 508 * maximum)
                out[i + 1] = Float16(Float(y % 251) / 250 * maximum * 0.5)
                out[i + 2] = Float16(Float((x * 7 + y * 13) % 97) / 96 * maximum * 0.25)
            }
        }
        out[out.count - 3] = Float16(maximum)
        return out
    }

    static func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
