import Foundation
import Metal
import ImageIO
import CoreGraphics
import CoreVideo
import ColorKit

/// An HDR gain map (ISO 21496-1) to attach to a JPEG or HEIC export.
///
/// A gain-map file is two pictures in one. The main image is the ordinary
/// SDR export, byte for byte what the file would hold without the map, so
/// every viewer that knows nothing about HDR shows exactly that. The map
/// says, per pixel and per channel, how many stops brighter or darker the
/// HDR rendition is; an HDR screen multiplies it back in, scaled by how
/// much headroom it has at the moment. The HDR rendition is the same edit
/// through the same pipeline with the tone curve's ceiling raised, exactly
/// what the editor's EDR display shows, so a file looks on an HDR screen
/// the way the photo looked while editing it.
///
/// macOS 15's ImageIO can also build a gain map itself from one
/// extended-range image, but then its own tone mapper makes the SDR base,
/// which would not match Latent's SDR export. Here both renditions are
/// Latent's, and ImageIO only stores the map it is given.
public struct GainMap: Sendable {
    /// Headroom of the HDR rendition, relative to SDR white. The editor
    /// caps its display at the same 4x (two stops): brighter reads as a
    /// searchlight rather than a highlight.
    public static let exportHeadroom: Float = 4

    /// Added to both renditions before the ratio, so near-black pixels
    /// (where a ratio of tiny numbers is noise) get a gain of about zero.
    /// The standard's suggested value.
    static let offset: Float = 1.0 / 64

    public let width: Int
    public let height: Int
    /// B, G, R, unused byte per pixel, row-major: the map's three channels.
    public let pixels: Data
    public let headroom: Float
    /// The gains, in stops, that the 0 and 255 of each channel stand for.
    public let minimumLog2: Float
    public let maximumLog2: Float

    /// The range of gains to encode for a headroom. The tone curve's
    /// ceiling only stretches highlights, up to `headroom` times brighter.
    /// It also keeps middle grey where it is, which pulls deep shadows down
    /// by up to H / (2H - 1) (Naka-Rushton, ColorPipeline.metal). A fixed
    /// range from the curve itself needs no pass over the pixels to find
    /// the extremes, and eight bits over its 2.8 stops (at 4x) is steps of
    /// a hundredth of a stop. Grading can nudge a pixel past either end;
    /// that pixel's HDR value is then held at the limit.
    static func log2Range(headroom: Float) -> (minimum: Float, maximum: Float) {
        let h = max(headroom, 1.0001)
        return (log2(h / (2 * h - 1)), log2(h))
    }

    /// The size a map is stored at: half the image's, rounded up, as
    /// ImageIO's own gain maps. Readers upsample it smoothly, and a quarter
    /// of the pixels keeps the file small and the extra GPU work light.
    static func size(forImageWidth width: Int, height: Int) -> (width: Int, height: Int) {
        (max(1, (width + 1) / 2), max(1, (height + 1) / 2))
    }

    /// The dictionary `CGImageDestinationAddAuxiliaryDataInfo` takes: the
    /// pixels, their layout, and the map's parameters as the XMP ImageIO
    /// reads and writes for ISO gain maps (namespace HDRToneMap), which
    /// it turns into the standard's binary form in the file. Headrooms are
    /// in stops: SDR (0) for the base, log2(headroom) for the alternate.
    var auxiliaryDataInfo: CFDictionary {
        let namespace = "http://ns.apple.com/HDRToneMap/1.0/" as CFString
        let prefix = "HDRToneMap" as CFString
        let metadata = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(metadata, namespace, prefix, nil)
        func set(_ path: String, _ value: CFTypeRef) {
            CGImageMetadataSetValueWithPath(metadata, nil, "HDRToneMap:\(path)" as CFString, value)
        }
        func tag(_ name: String, _ type: CGImageMetadataType, _ value: CFTypeRef) -> CGImageMetadataTag? {
            CGImageMetadataTagCreate(namespace, prefix, name as CFString, type, value)
        }
        set("Version", 1 as CFNumber)
        set("BaseHeadroom", 0.0 as CFNumber)
        set("AlternateHeadroom", Double(log2(headroom)) as CFNumber)
        set("BaseColorIsWorkingColor", kCFBooleanTrue)

        // Same parameters for all three channels; the pixels differ.
        var channel: [String: CGImageMetadataTag] = [:]
        for (name, value) in [("GainMapMin", Double(minimumLog2)), ("GainMapMax", Double(maximumLog2)),
                              ("Gamma", 1.0), ("BaseOffset", Double(Self.offset)),
                              ("AlternateOffset", Double(Self.offset))] {
            channel[name] = tag(name, .default, value as CFNumber)
        }
        if let sequence = tag("ChannelMetadata", .arrayOrdered, [] as CFArray) {
            CGImageMetadataSetTagWithPath(metadata, nil, "HDRToneMap:ChannelMetadata" as CFString, sequence)
            for index in 0..<3 {
                if let entry = tag("[\(index)]", .structure, channel as CFDictionary) {
                    CGImageMetadataSetTagWithPath(metadata, nil, "HDRToneMap:ChannelMetadata[\(index)]" as CFString, entry)
                }
            }
        }

        let description: [CFString: Any] = [
            kCGImagePropertyWidth: width,
            kCGImagePropertyHeight: height,
            kCGImagePropertyBytesPerRow: width * 4,
            kCGImagePropertyPixelFormat: kCVPixelFormatType_32BGRA,
        ]
        return [
            kCGImageAuxiliaryDataInfoData: pixels as CFData,
            kCGImageAuxiliaryDataInfoDataDescription: description as CFDictionary,
            kCGImageAuxiliaryDataInfoMetadata: metadata,
        ] as CFDictionary
    }
}

/// Mirror of `GainMapUniforms` in Export.metal.
struct GainMapUniforms {
    var minLog2: Float
    var maxLog2: Float
    var baseOffset: Float
    var alternateOffset: Float
}

extension RenderOutput {
    /// A file's HDR rendition, for a gain map: the file's primaries, the
    /// tone curve's ceiling at `headroom`, linear light, nothing clipped at
    /// SDR white. The EDR display's output in another colour space.
    public static func hdrFile(_ space: ColorKit.OutputSpace, headroom: Float) -> RenderOutput {
        RenderOutput(space: space, headroom: max(1, headroom), encoded: false)
    }
}

extension Exporter {
    /// `write` for a JPEG or HEIC with a gain map. `texture` is the SDR
    /// render; `hdrRender` renders the same edit for another output.
    ///
    /// Order matters. The pipeline pools its output textures by role, so
    /// the HDR render reuses, and overwrites, the SDR one. Everything the
    /// SDR render is needed for (the file's pixels and the map's base) is
    /// read before the HDR render runs.
    func writeWithGainMap(_ texture: MTLTexture, to url: URL, settings: ExportSettings,
                          colorSpace: ColorKit.OutputSpace, rotation: ImageRotation, crop: CropParameters,
                          metadata: ExportMetadata?, maxLongEdge: Int?, replacingExisting: Bool = true,
                          hdrRender: (RenderOutput) throws -> MTLTexture) throws -> (width: Int, height: Int) {
        let headroom = GainMap.exportHeadroom
        let base = try linearTexture(from: texture, rotation: rotation, crop: crop,
                                     maxLongEdge: maxLongEdge, sourceIsEncoded: true)
        let image = try cgImage(from: texture, colorSpace: colorSpace, rotation: rotation, crop: crop,
                                bitsPerComponent: settings.format.bitsPerComponent, maxLongEdge: maxLongEdge)
        let hdr = try hdrRender(.hdrFile(colorSpace, headroom: headroom))
        let alternate = try linearTexture(from: hdr, rotation: rotation, crop: crop,
                                          maxLongEdge: maxLongEdge, sourceIsEncoded: false)
        let map = try gainMap(base: base, alternate: alternate, headroom: headroom)
        try Self.write(cgImage: image, to: url, settings: settings, metadata: metadata, gainMap: map,
                       replacingExisting: replacingExisting)
        return (image.width, image.height)
    }

    /// A render cropped, rotated and resampled to gain-map size (half the
    /// export's), in linear light, as a private float texture.
    func linearTexture(from texture: MTLTexture, rotation: ImageRotation, crop: CropParameters,
                       maxLongEdge: Int?, sourceIsEncoded: Bool) throws -> MTLTexture {
        let frame = CropFrame(sensorSize: CGSize(width: texture.width, height: texture.height),
                              crop: crop, rotation: rotation)
        let (w, h) = Self.outputSize(frame: frame, maxLongEdge: maxLongEdge)
        let size = GainMap.size(forImageWidth: w, height: h)
        guard let dest = gpu.makePrivateTexture(width: size.width, height: size.height,
                                                pixelFormat: .rgba16Float) else {
            throw ExportError.readbackFailed
        }
        try resample(texture, frame: frame, into: dest, sourceIsEncoded: sourceIsEncoded, encode: false)
        return dest
    }

    /// The map from two linear renditions of the same size.
    func gainMap(base: MTLTexture, alternate: MTLTexture, headroom: Float) throws -> GainMap {
        let w = base.width, h = base.height
        let range = GainMap.log2Range(headroom: headroom)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        descriptor.storageMode = .shared     // handed to ImageIO straight after
        descriptor.usage = [.shaderWrite]
        let pso = gpu.exportGainMapPSO
        guard let dest = gpu.device.makeTexture(descriptor: descriptor),
              let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else {
            throw ExportError.readbackFailed
        }
        encoder.setComputePipelineState(pso)
        encoder.setTexture(base, index: 0)
        encoder.setTexture(alternate, index: 1)
        encoder.setTexture(dest, index: 2)
        var uniforms = GainMapUniforms(minLog2: range.minimum, maxLog2: range.maximum,
                                       baseOffset: GainMap.offset, alternateOffset: GainMap.offset)
        encoder.setBytes(&uniforms, length: MemoryLayout<GainMapUniforms>.size, index: 0)
        let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        cmdBuffer.commit()
        cmdBuffer.waitUntilCompleted()
        guard cmdBuffer.status != .error else { throw ExportError.readbackFailed }

        var pixels = Data(count: w * h * 4)
        pixels.withUnsafeMutableBytes { bytes in
            dest.getBytes(bytes.baseAddress!, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        return GainMap(width: w, height: h, pixels: pixels, headroom: headroom,
                       minimumLog2: range.minimum, maximumLog2: range.maximum)
    }
}
