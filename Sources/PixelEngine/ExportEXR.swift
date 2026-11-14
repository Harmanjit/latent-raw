import Foundation
import Metal
import CoreGraphics

/// OpenEXR export: the scene-linear render (`RenderOutput.sceneLinear`,
/// what a DNG export bakes: white balance, exposure, noise reduction, lens
/// corrections, healing and masks, with the look left out) written as
/// half or full float through ImageIO, at full size, cropped and upright.
///
/// ImageIO stores an EXR's pixels in linear sRGB primaries whatever space
/// the image is tagged with, and writes no chromaticities (measured), so
/// the Rec. 2020 render is converted to extended linear sRGB, where
/// colours outside sRGB keep their negative components rather than being
/// clipped (`Exporter.finalPixels`).
public struct EXROptions: Sendable, Hashable, Codable {
    /// 16-bit half floats (the default, what compositing apps expect) or
    /// 32-bit floats.
    public var half = true

    public init(half: Bool = true) { self.half = half }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        half = (try? c.decodeIfPresent(Bool.self, forKey: .half)) ?? true
    }
}

extension Exporter {
    /// Writes `texture` (rgba16Float, linear Rec. 2020, as
    /// `sceneLinearTexture` makes it) as an OpenEXR file. Waits for the GPU.
    @discardableResult
    public static func writeEXR(linearRec2020 texture: MTLTexture, commandQueue: MTLCommandQueue,
                                settings: ExportSettings, metadata: ExportMetadata? = nil, to url: URL,
                                replacingExisting: Bool = true) throws -> (width: Int, height: Int) {
        let image = try linearImage(halfFloatRGBA: texture, commandQueue: commandQueue)
        var settings = settings
        settings.format = .exr
        try write(cgImage: image, to: url, settings: settings, metadata: metadata, replacingExisting: replacingExisting)
        return (image.width, image.height)
    }

    /// A 16-bit float CGImage of an rgba16Float texture in extended linear
    /// Rec. 2020, copied to the CPU (through a shared texture when the
    /// texture is private to the GPU).
    static func linearImage(halfFloatRGBA texture: MTLTexture, commandQueue: MTLCommandQueue) throws -> CGImage {
        let w = texture.width, h = texture.height, bytesPerRow = w * 8
        var readable = texture
        if texture.storageMode == .private {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: w,
                                                                      height: h, mipmapped: false)
            descriptor.storageMode = .shared
            guard let shared = texture.device.makeTexture(descriptor: descriptor),
                  let buffer = commandQueue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() else {
                throw ExportError.readbackFailed
            }
            blit.copy(from: texture, to: shared)
            blit.endEncoding()
            buffer.commit()
            buffer.waitUntilCompleted()
            guard buffer.status != .error else { throw ExportError.readbackFailed }
            readable = shared
        }
        var data = Data(count: bytesPerRow * h)
        data.withUnsafeMutableBytes { bytes in
            readable.getBytes(bytes.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, w, h),
                              mipmapLevel: 0)
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020),
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: bytesPerRow,
                                  space: space, bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else {
            throw ExportError.imageCreationFailed
        }
        return image
    }
}
