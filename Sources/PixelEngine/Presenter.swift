import Foundation
import Metal
import QuartzCore
import simd

/// One texture and where it belongs in sensor space.
public struct PresentLayer {
    public let texture: MTLTexture
    /// The sensor rectangle the texture covers.
    public let coverage: CGRect
    /// Pixels to trim from every edge before drawing. Full-resolution
    /// tiles set this to hide the demosaic's degraded border.
    public let inset: CGFloat

    public init(texture: MTLTexture, coverage: CGRect, inset: CGFloat = 0) {
        self.texture = texture
        self.coverage = coverage
        self.inset = inset
    }
}

/// Draws rendered textures into a CAMetalLayer drawable.
///
/// Kept separate from RenderPipeline because it isn't image processing —
/// it's display plumbing. The pipeline produces correct images covering
/// some sensor rectangles; this places them on screen according to the
/// current zoom and pan.
///
/// Presenting is cheap (one sampling pass over the drawable), so it runs on
/// every gesture event without waiting for the pipeline. The base layer is
/// the whole image at preview resolution and is always drawn; the optional
/// tile is a full-resolution render of the visible area drawn on top. Mid-
/// gesture the tile may not cover the window, and the base shows through
/// softly until the pipeline catches up.
///
/// Known gap (DESIGN.md §8.3): this presents bounded, already-encoded sRGB.
/// Real EDR display means keeping the pipeline output extended-linear and
/// doing the display transform here instead, so highlights above diffuse
/// white survive to the screen. That's a deliberate later change.
public final class Presenter {
    private let gpu: GPUContext

    public init(gpu: GPUContext) {
        self.gpu = gpu
    }

    /// Computes where an image of `imageSize` sits inside `drawableSize`
    /// when scaled to fit while preserving aspect ratio.
    public static func fitRect(imageSize: CGSize, drawableSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(drawableSize.width / imageSize.width,
                         drawableSize.height / imageSize.height)
        let fitted = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (drawableSize.width - fitted.width) / 2,
                       y: (drawableSize.height - fitted.height) / 2,
                       width: fitted.width, height: fitted.height)
    }

    /// Draws `texture` fitted and letterboxed — the whole texture, centred.
    public func present(_ texture: MTLTexture,
                         to drawable: CAMetalDrawable,
                         backgroundLevel: Float = 0.12) {
        let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let imageSize = CGSize(width: texture.width, height: texture.height)
        let transform = ViewportTransform.fit(imageSize: imageSize, drawableSize: drawableSize)
        present(base: PresentLayer(texture: texture, coverage: CGRect(origin: .zero, size: imageSize)),
                tile: nil, transform: transform, rotation: .none, sensorSize: imageSize,
                to: drawable, backgroundLevel: backgroundLevel)
    }

    /// Draws the base layer, then the tile on top if there is one, both
    /// placed by `transform` (which works in rotated image space) and
    /// `rotation` (which maps that back onto the unrotated textures).
    public func present(base: PresentLayer,
                         tile: PresentLayer?,
                         transform: ViewportTransform,
                         rotation: ImageRotation,
                         sensorSize: CGSize,
                         to drawable: CAMetalDrawable,
                         backgroundLevel: Float = 0.12) {
        let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let baseMap = transform.screenToTextureMap(coverage: base.coverage, rotation: rotation,
                                                   sensorSize: sensorSize, drawableSize: drawableSize)

        var tileMap = baseMap
        var tileSource = SIMD4<Float>(0, 0, 1, 1)
        if let tile {
            let shown = tile.coverage.insetBy(dx: tile.inset, dy: tile.inset)
            tileMap = transform.screenToTextureMap(coverage: shown, rotation: rotation,
                                                   sensorSize: sensorSize, drawableSize: drawableSize)
            let w = Float(tile.texture.width), h = Float(tile.texture.height)
            let i = Float(tile.inset)
            tileSource = SIMD4<Float>(i / w, i / h, (w - 2 * i) / w, (h - 2 * i) / h)
        }

        draw(base: base.texture, baseMap: baseMap,
             tile: tile?.texture, tileMap: tileMap, tileSource: tileSource,
             into: drawable, backgroundLevel: backgroundLevel)
    }

    private func draw(base: MTLTexture, baseMap: simd_float3x2,
                      tile: MTLTexture?, tileMap: simd_float3x2, tileSource: SIMD4<Float>,
                      into drawable: CAMetalDrawable, backgroundLevel: Float) {
        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(gpu.presentPSO)
        encoder.setTexture(base, index: 0)
        // Metal requires every declared texture slot to be bound, even if
        // the kernel won't read it this time.
        encoder.setTexture(tile ?? base, index: 1)
        encoder.setTexture(drawable.texture, index: 2)

        var baseMapV = baseMap
        var tileMapV = tileMap
        var tileSourceV = tileSource
        var hasTile: UInt32 = tile == nil ? 0 : 1
        var background = backgroundLevel
        encoder.setBytes(&baseMapV, length: MemoryLayout<simd_float3x2>.size, index: 0)
        encoder.setBytes(&tileMapV, length: MemoryLayout<simd_float3x2>.size, index: 1)
        encoder.setBytes(&tileSourceV, length: 16, index: 2)
        encoder.setBytes(&hasTile, length: 4, index: 3)
        encoder.setBytes(&background, length: 4, index: 4)

        let pso = gpu.presentPSO
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        let groups = MTLSize(width: (drawable.texture.width + tw - 1) / tw,
                              height: (drawable.texture.height + th - 1) / th,
                              depth: 1)
        encoder.dispatchThreadgroups(groups,
                                      threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }
}
