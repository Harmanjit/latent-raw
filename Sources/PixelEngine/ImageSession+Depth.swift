import Foundation
import Metal

// The depth map Lens Blur reads (LensBlur.swift). Made by MLKit from the
// picture and handed over here, like the touch-up masks; the session only
// keeps it and uploads it once. It is small (a model's 518-pixel output,
// or a subject mask), so memory pressure leaves it alone: dropping it
// would cost a model run to save well under a megabyte.
extension ImageSession {
    /// The depth map on hand, or nil until MLKit has made one.
    public var depthMap: DepthMap? { depthStore?.map }

    public var hasDepthMap: Bool { depthStore != nil }

    /// Replaces the depth map (nil drops it). The texture is made again
    /// on the next render that wants it.
    public func setDepthMap(_ map: DepthMap?) {
        depthStore = map.map { ($0, nil) }
    }

    /// The depth map as an r8Unorm texture at its own size, shared
    /// storage since the CPU writes it; nil without a map, which is what
    /// tells the pipeline to skip the stage.
    func depthTexture() -> MTLTexture? {
        guard let store = depthStore else { return nil }
        if let texture = store.texture { return texture }
        let bitmap = store.map.bitmap
        guard bitmap.width > 0, bitmap.height > 0, bitmap.data.count == bitmap.width * bitmap.height else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: bitmap.width,
                                                         height: bitmap.height, mipmapped: false)
        d.storageMode = .shared
        d.usage = [.shaderRead]
        guard let texture = gpu.device.makeTexture(descriptor: d) else { return nil }
        bitmap.data.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, bitmap.width, bitmap.height), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: bitmap.width)
        }
        depthStore = (store.map, texture)
        return texture
    }
}
