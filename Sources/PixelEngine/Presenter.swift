import Foundation
import Metal
import QuartzCore

/// Draws a rendered texture into a CAMetalLayer drawable.
///
/// Kept separate from RenderPipeline because it isn't image processing —
/// it's display plumbing. The pipeline produces a correct image covering
/// some sensor rectangle; this places that rectangle on screen according
/// to the current zoom and pan.
///
/// Presenting is cheap (one sampling pass over the drawable), so it runs on
/// every gesture event without waiting for the pipeline. If the texture on
/// hand is a low-resolution preview and the user has zoomed in, it's
/// upscaled and looks soft for a moment; the pipeline then re-renders at
/// the right resolution and the next present sharpens it.
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
        let rect = Self.fitRect(imageSize: imageSize, drawableSize: drawableSize)
        draw(texture, into: drawable, at: rect, backgroundLevel: backgroundLevel)
    }

    /// Draws `texture`, which covers `coverage` in sensor space, placed by
    /// `transform`. Parts of the drawable the texture doesn't reach are
    /// filled with the neutral surround.
    public func present(_ texture: MTLTexture,
                         covering coverage: CGRect,
                         transform: ViewportTransform,
                         to drawable: CAMetalDrawable,
                         backgroundLevel: Float = 0.12) {
        let drawableSize = CGSize(width: drawable.texture.width, height: drawable.texture.height)
        let rect = transform.screenRect(forSensorRect: coverage, drawableSize: drawableSize)
        draw(texture, into: drawable, at: rect, backgroundLevel: backgroundLevel)
    }

    private func draw(_ texture: MTLTexture, into drawable: CAMetalDrawable,
                      at rect: CGRect, backgroundLevel: Float) {
        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else { return }

        encoder.setComputePipelineState(gpu.presentPSO)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(drawable.texture, index: 1)

        var origin = SIMD2<Float>(Float(rect.origin.x), Float(rect.origin.y))
        var size = SIMD2<Float>(Float(rect.width), Float(rect.height))
        var background = backgroundLevel
        encoder.setBytes(&origin, length: 8, index: 0)
        encoder.setBytes(&size, length: 8, index: 1)
        encoder.setBytes(&background, length: 4, index: 2)

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
