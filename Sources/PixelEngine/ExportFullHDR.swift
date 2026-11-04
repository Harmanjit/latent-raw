import Foundation
import Metal
import CoreGraphics
import ColorKit
import simd

/// Full HDR export: HDR Output with Maximize Compatibility off.
///
/// A gain-map file (GainMap.swift) is an SDR picture with a recipe for
/// brightening it, so every viewer shows something sensible. A full HDR
/// file is the HDR rendition itself, stored in Rec. 2100 PQ at 10 bits
/// (HEIC or AVIF): viewers that understand PQ show it as the editor's EDR
/// display did, and older ones tone-map it themselves, sometimes badly.
/// That is the trade Lightroom's "Maximize Compatibility" switch names.
///
/// The HDR rendition is the same render a gain map's alternate uses
/// (`RenderOutput.hdrFile`, the tone curve's ceiling at the photo's HDR
/// Limit), in linear light with SDR white at 1.0. Core Graphics converts it
/// to PQ, placing 1.0 at 203 cd/m², the reference white of ITU-R BT.2408
/// (measured), so SDR white in the file is where HDR displays expect it and
/// the highlights reach 203 × headroom. ImageIO then encodes the 16-bit PQ
/// image at 10 bits and writes the HDR metadata itself.
extension Exporter {
    /// `encodableImage` for a full HDR file. The SDR render the caller
    /// already made isn't used: only `hdrRender`'s output is.
    func fullHDRImage(settings: ExportSettings, colorSpace: ColorKit.OutputSpace, rotation: ImageRotation,
                      crop: CropParameters, maxLongEdge: Int?, headroom: Float,
                      hdrRender: (RenderOutput) throws -> MTLTexture) throws -> EncodableImage {
        let hdr = try hdrRender(.hdrFile(colorSpace, headroom: headroom))
        let linear = try fullSizeLinearTexture(from: hdr, rotation: rotation, crop: crop, maxLongEdge: maxLongEdge,
                                               enlarge: settings.enlarges)
        return EncodableImage(image: try Self.pqImage(halfFloatRGBA: linear, colorSpace: colorSpace))
    }

    /// A linear render cropped, turned and sized to the export's size, as
    /// a shared rgba16Float texture the CPU reads. Nothing is clamped at
    /// SDR white; negatives are cut to zero.
    func fullSizeLinearTexture(from texture: MTLTexture, rotation: ImageRotation, crop: CropParameters,
                               maxLongEdge: Int?, enlarge: Bool) throws -> MTLTexture {
        let frame = CropFrame(sensorSize: CGSize(width: texture.width, height: texture.height),
                              crop: crop, rotation: rotation)
        let (w, h) = Self.outputSize(frame: frame, maxLongEdge: maxLongEdge, enlarge: enlarge)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared     // read by the CPU straight after
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let dest = gpu.device.makeTexture(descriptor: descriptor) else { throw ExportError.readbackFailed }
        if (w, h) != Self.outputSize(frame: frame, maxLongEdge: nil) {
            try resample(texture, frame: frame, into: dest, sourceIsEncoded: false, encode: false)
            return dest
        }
        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else { throw ExportError.readbackFailed }
        let pso = gpu.exportSampleLinearPSO
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(dest, index: 1)
        var map = frame.normalizedSamplingMap()
        var decode: UInt32 = 0
        encoder.setBytes(&map, length: MemoryLayout<simd_float3x2>.size, index: 0)
        encoder.setBytes(&decode, length: 4, index: 1)
        let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        guard cmdBuffer.status != .error else { throw ExportError.readbackFailed }
        return dest
    }

    /// The extended-linear colour space for a render's primaries.
    static func extendedLinearSpace(for space: ColorKit.OutputSpace) -> CGColorSpace? {
        switch space {
        case .sRGB:      return CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        case .displayP3: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        case .rec2020:   return CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)
        }
    }

    /// A 16-bit Rec. 2100 PQ image of linear half-float pixels (SDR white
    /// at 1.0) in `colorSpace`'s primaries.
    static func pqImage(halfFloatRGBA texture: MTLTexture, colorSpace: ColorKit.OutputSpace) throws -> CGImage {
        let w = texture.width, h = texture.height, bytesPerRow = w * 8
        var data = Data(count: bytesPerRow * h)
        data.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, w, h),
                             mipmapLevel: 0)
        }
        return try pqImage(halfFloatRGBA: data, width: w, height: h, colorSpace: colorSpace)
    }

    /// `pqImage` from pixels already in memory: RGBA half floats, row-major.
    static func pqImage(halfFloatRGBA data: Data, width w: Int, height h: Int,
                        colorSpace: ColorKit.OutputSpace) throws -> CGImage {
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)
        guard let linearSpace = extendedLinearSpace(for: colorSpace),
              let pqSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ),
              let provider = CGDataProvider(data: data as CFData),
              let linear = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: w * 8,
                                   space: linearSpace, bitmapInfo: info, provider: provider, decode: nil,
                                   shouldInterpolate: false, intent: .defaultIntent),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 16, bytesPerRow: 0,
                                      space: pqSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                                          | CGBitmapInfo.byteOrder16Little.rawValue) else {
            throw ExportError.imageCreationFailed
        }
        context.interpolationQuality = .none
        context.draw(linear, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = context.makeImage() else { throw ExportError.imageCreationFailed }
        return image
    }
}
