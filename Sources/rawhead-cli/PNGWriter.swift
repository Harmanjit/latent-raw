import Foundation
import Metal
import ImageIO
import UniformTypeIdentifiers

enum PNGWriteError: Error { case blitFailed, cgImageFailed, destinationFailed }

/// Writes a rendered texture out as an 8-bit PNG.
///
/// The input is expected to be **already display-encoded** — the colour
/// stage (ColorPipeline.metal) applies the camera matrix, tone mapping, the
/// output-space transform and the sRGB encoding curve. This function only
/// quantizes to 8 bits and tags the file.
///
/// It used to apply its own pow(1/2.2) curve, which was a stopgap while the
/// pipeline had no colour management at all. Leaving that in now would
/// double-encode and wash the image out badly.
///
/// Still not the real export path — that arrives in Phase 6 with ICC
/// profile embedding, soft-proofing and HDR gain maps.
func writePNG(texture: MTLTexture, to path: String) throws {
    let device = texture.device
    guard let queue = device.makeCommandQueue() else { throw PNGWriteError.blitFailed }

    // Pipeline textures are private-storage (DESIGN.md §7.2), which the CPU
    // cannot read at all. Blit into a shared-storage copy first — reading a
    // private texture directly faults inside the GPU driver.
    let readableDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height,
        mipmapped: false)
    readableDescriptor.storageMode = .shared
    readableDescriptor.usage = [.shaderRead]
    guard let readableTexture = device.makeTexture(descriptor: readableDescriptor) else {
        throw PNGWriteError.blitFailed
    }

    guard let cmdBuffer = queue.makeCommandBuffer(),
          let blit = cmdBuffer.makeBlitCommandEncoder() else {
        throw PNGWriteError.blitFailed
    }
    blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
              sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
              sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
              to: readableTexture, destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
    cmdBuffer.commit()
    cmdBuffer.waitUntilCompleted()
    if cmdBuffer.status == .error { throw PNGWriteError.blitFailed }

    var floatData = [Float16](repeating: 0, count: texture.width * texture.height * 4)
    readableTexture.getBytes(&floatData,
                              bytesPerRow: texture.width * 4 * MemoryLayout<Float16>.size,
                              from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                              mipmapLevel: 0)

    var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    for i in 0..<(texture.width * texture.height) {
        for c in 0..<3 {
            let v = Float(floatData[i * 4 + c])
            pixels[i * 4 + c] = UInt8(max(0, min(1, v)) * 255)
        }
        pixels[i * 4 + 3] = 255
    }

    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let cgImage = CGImage(width: texture.width, height: texture.height,
                                 bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: texture.width * 4,
                                 space: colorSpace,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: false,
                                 intent: .defaultIntent)
    else { throw PNGWriteError.cgImageFailed }

    guard let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw PNGWriteError.destinationFailed }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else { throw PNGWriteError.destinationFailed }
}
