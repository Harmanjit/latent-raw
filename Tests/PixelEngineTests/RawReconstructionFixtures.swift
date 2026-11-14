import XCTest
import Metal
@testable import PixelEngine
@testable import RawCore

/// Small synthetic Bayer raws for the raw-reconstruction tests (Inpaint
/// Opposed, embedded DNG corrections): RGGB, black 0, white 1000, made in
/// memory, so the tests run anywhere.
enum RawReconstructionFixtures {
    static let order: UInt8 = 0x94   // RGGB

    static func summary(width: Int, height: Int,
                        multipliers: (Float, Float, Float, Float) = (2, 1, 1.5, 1)) -> RawSummary {
        RawSummary(activeArea: SensorActiveArea(left: 0, top: 0, width: width, height: height,
                                                fullWidth: width, fullHeight: height),
                   cfaPattern: .bayer(order: order), cameraMultipliers: multipliers,
                   blackLevel: 0, whiteLevel: 1000, channelBlackLevels: SIMD4(repeating: 0),
                   dataMaximum: 1000, baselineExposure: 0, mergeInfo: nil,
                   cameraMake: "Test", cameraModel: "Synthetic", lensModel: "",
                   iso: 100, shutter: 0.01, aperture: 8, focalLength: 50,
                   captureTime: Date(timeIntervalSince1970: 0), orientation: 0,
                   lens: LensIdentity(make: "", makerNotesName: "", makerLensID: 0, nikonLensID: 0, nikonLensType: 0,
                                      minFocal: 0, maxFocal: 0, maxApertureAtMinFocal: 0, maxApertureAtMaxFocal: 0,
                                      cropFactor: 0))
    }

    /// An invertible XYZ-to-camera matrix, so the session has a profile.
    static let cameraMatrix: [Float] = [0.75, 0.2, 0.05, 0.25, 0.7, 0.05, 0.05, 0.15, 0.8]

    /// The RGB channel (0, 1, 2) of photosite (x, y).
    static func channel(_ x: Int, _ y: Int) -> Int {
        let c = Int(order >> UInt8((((y & 1) << 1) | (x & 1)) * 2)) & 3
        return c == 3 ? 1 : c
    }

    /// A raw whose photosite at (x, y) reads `value(x, y)` in its channel.
    static func file(width: Int, height: Int, value: (Int, Int) -> SIMD3<Float>) throws -> RawFile {
        var samples = [UInt16](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let v = value(x, y)[channel(x, y)]
                samples[y * width + x] = UInt16(min(max(v, 0), 1000).rounded())
            }
        }
        let made = samples.withUnsafeBufferPointer {
            RawFile.bayerSource(width: width, height: height, like: summary(width: width, height: height),
                                cameraToXYZ: cameraMatrix, dataMaximum: 1000, samples: $0)
        }
        return try XCTUnwrap(made)
    }

    /// A shared rgba32Float texture holding `pixels` (four floats each).
    static func texture(_ pixels: [Float], width: Int, height: Int, gpu: GPUContext) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: width, height: height,
                                                         mipmapped: false)
        d.storageMode = .shared
        d.usage = [.shaderRead, .shaderWrite]
        let tex = try XCTUnwrap(gpu.device.makeTexture(descriptor: d))
        pixels.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: width * 16)
        }
        return tex
    }

    static func floats(_ texture: MTLTexture, gpu: GPUContext) throws -> [Float] {
        if texture.pixelFormat == .rgba16Float {
            return try TextureReadback.float16Pixels(of: texture, gpu: gpu).map { Float($0) }
        }
        var out = [Float](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&out, bytesPerRow: texture.width * 16,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return out
    }
}
