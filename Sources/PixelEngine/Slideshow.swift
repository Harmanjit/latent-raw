import Foundation
import Metal
import QuartzCore
import CoreGraphics
import simd

// The slideshow's drawing, ported from minivu's SlideshowRenderer: the
// transitions, where each slide sits on screen during one, and the pass
// that draws a frame. Slides themselves are rendered by
// `ExportWorker.renderForScreen` (MLKit), through the same pipeline and
// exporter passes as an exported file, at the size the screen shows them.

/// How one slide gives way to the next.
///
/// Raw values are stored in settings, so they must never change.
public enum SlideshowTransition: String, Codable, CaseIterable, Sendable, Identifiable {
    /// No transition: the next slide replaces the last at once.
    case cut
    case crossFade
    case fadeThroughBlack
    /// The new slide pushes the old one off the screen.
    case push
    /// The old slide grows and fades while the new one settles from slightly smaller.
    case zoom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cut: "Cut"
        case .crossFade: "Cross-Fade"
        case .fadeThroughBlack: "Fade Through Black"
        case .push: "Push"
        case .zoom: "Zoom"
        }
    }

    /// What plays with Reduce Motion on: transitions that move the picture
    /// (push, zoom) become a cross-fade; the cut and the fades, which change
    /// in place, stay as chosen.
    public func reducingMotion(_ reduced: Bool) -> SlideshowTransition {
        guard reduced else { return self }
        switch self {
        case .cut, .crossFade, .fadeThroughBlack: return self
        case .push, .zoom: return .crossFade
        }
    }

    /// Whether a frame is drawn between the two slides at all.
    public var animates: Bool { self != .cut }

    /// The shader's mix kind (`slideshowFragment`).
    var shaderKind: Float {
        switch self {
        case .cut, .crossFade, .zoom: 0
        case .fadeThroughBlack: 1
        case .push: 2
        }
    }
}

/// Which way the show is moving, for transitions with a direction:
/// forward, the new slide arrives from the right; backward, from the left.
public enum SlideshowDirection: Sendable, Equatable {
    case forward, backward
}

public enum SlideshowEasing {
    /// Slow in and out, symmetric (smoothstep): 0, ½ and 1 map to
    /// themselves, so a cross-fade half way through in time is an even mix.
    public static func easeInOut(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }
}

/// A slide ready to show: an 8-bit, display-encoded Display P3 texture the
/// size the screen shows it, private to the GPU.
///
/// Sendable because nothing writes the texture once it is made, and Metal
/// textures may be read from any thread.
public struct SlideTexture: @unchecked Sendable {
    public let texture: MTLTexture
    public var pixelSize: CGSize { CGSize(width: texture.width, height: texture.height) }

    public init(texture: MTLTexture) {
        self.texture = texture
    }
}

/// Everything the slideshow needs to draw one frame. A slide at rest is a
/// finished transition: `to` the slide, progress 1.
public struct SlideshowFrame {
    /// The slide going away; nil for black.
    public var from: SlideTexture?
    /// The slide arriving; nil for black.
    public var to: SlideTexture?
    public var transition: SlideshowTransition
    /// Time through the transition, 0...1. The renderer eases it.
    public var progress: Float
    public var direction: SlideshowDirection

    public init(from: SlideTexture?, to: SlideTexture?, transition: SlideshowTransition,
                progress: Float, direction: SlideshowDirection = .forward) {
        self.from = from
        self.to = to
        self.transition = transition
        self.progress = progress
        self.direction = direction
    }

    /// `slide` alone, as it rests between transitions.
    public static func still(_ slide: SlideTexture?) -> SlideshowFrame {
        SlideshowFrame(from: nil, to: slide, transition: .cut, progress: 1)
    }
}

/// Where slides sit on screen and how large they are rendered. Plain
/// arithmetic, so it is unit tested and the shader only mixes.
public enum SlideshowGeometry {
    /// How far the old slide has grown by the end of a zoom.
    public static let zoomOutgoingScale: CGFloat = 1.3
    /// How small the new slide starts in a zoom.
    public static let zoomIncomingScale: CGFloat = 0.9

    /// `image` scaled to fit inside `bounds`, keeping its shape, in whole
    /// pixels. Larger or smaller, it fills the space it can: a slide
    /// rendered a pixel short of the screen (a tight crop, rounding) is
    /// drawn at the size of its neighbours.
    public static func fittedSize(_ image: CGSize, in bounds: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let zoom = min(bounds.width / image.width, bounds.height / image.height)
        return CGSize(width: max(1, (image.width * zoom).rounded()), height: max(1, (image.height * zoom).rounded()))
    }

    /// The image aspect-fit and centred in the view (top-left origin).
    public static func fitRect(imageSize: CGSize, viewSize: CGSize) -> CGRect {
        let size = fittedSize(imageSize, in: viewSize)
        guard size.width > 0 else { return .zero }
        return CGRect(x: ((viewSize.width - size.width) / 2).rounded(),
                      y: ((viewSize.height - size.height) / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// The rectangles of the old and new slide at eased progress `t`: push
    /// moves them a screen's width along the direction of travel, zoom
    /// scales them about their centres.
    public static func rects(transition: SlideshowTransition, progress t: CGFloat, direction: SlideshowDirection,
                             fromImage: CGSize?, toImage: CGSize?,
                             viewSize: CGSize) -> (from: CGRect?, to: CGRect?) {
        var from = fromImage.map { fitRect(imageSize: $0, viewSize: viewSize) }
        var to = toImage.map { fitRect(imageSize: $0, viewSize: viewSize) }
        let sign: CGFloat = direction == .forward ? 1 : -1
        switch transition {
        case .push:
            from = from?.offsetBy(dx: -sign * t * viewSize.width, dy: 0)
            to = to?.offsetBy(dx: sign * (1 - t) * viewSize.width, dy: 0)
        case .zoom:
            from = from.map { scaled($0, by: 1 + (zoomOutgoingScale - 1) * t) }
            to = to.map { scaled($0, by: zoomIncomingScale + (1 - zoomIncomingScale) * t) }
        case .cut, .crossFade, .fadeThroughBlack:
            break
        }
        return (from, to)
    }

    private static func scaled(_ rect: CGRect, by factor: CGFloat) -> CGRect {
        let width = rect.width * factor, height = rect.height * factor
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// The size to render a slide at, and how far to bin the raw for it.
    ///
    /// `sensor` is the raw's size, `canvas` the image after crop and
    /// quarter turns (`CropFrame.canvasSize`), `screen` the picture area in
    /// pixels. The slide is the canvas fitted to the screen, never enlarged
    /// past the canvas. `sensorLongEdge` is the long edge the whole
    /// uncropped frame must render at so the crop still covers the slide:
    /// the value to give `ExportPlan.scale`, which bins the frame as far as
    /// that allows. (Giving it the slide's own long edge would bin a
    /// cropped image below the slide's size.)
    public static func renderPlan(sensor: CGSize, canvas: CGSize,
                                  screen: CGSize) -> (slideLongEdge: Int, sensorLongEdge: Int) {
        guard sensor.width > 0, sensor.height > 0, canvas.width > 0, canvas.height > 0 else { return (0, 0) }
        var slide = fittedSize(canvas, in: screen)
        if slide.width > canvas.width || slide.height > canvas.height { slide = canvas }
        let slideLong = max(slide.width, slide.height)
        let reduction = slideLong / max(canvas.width, canvas.height)
        let sensorLong = max(sensor.width, sensor.height) * reduction
        return (Int(slideLong.rounded()), Int(sensorLong.rounded(.up)))
    }
}

/// Mirror of `SlideshowUniforms` in Slideshow.metal. All float4, so the
/// Swift and Metal layouts cannot drift apart through padding.
struct SlideshowUniforms {
    var fromRect = SIMD4<Float>()
    var toRect = SIMD4<Float>()
    var info = SIMD4<Float>()
    var params = SIMD4<Float>()
    var view = SIMD4<Float>()
}

/// Draws slideshow frames into a CAMetalLayer set up like the viewport's
/// (half-float, extended linear Display P3), or into a texture for tests.
/// One render pass per frame; nothing runs between frames.
public final class SlideshowRenderer {
    /// The same format as the viewport's layer.
    public static let pixelFormat: MTLPixelFormat = .rgba16Float

    private let gpu: GPUContext
    private let pipeline: MTLRenderPipelineState
    /// Bound in place of a missing slide: Metal wants every texture the
    /// shader names bound, even one a branch never samples.
    private let black: MTLTexture

    public init(gpu: GPUContext) throws {
        self.gpu = gpu
        guard let vertex = gpu.library.makeFunction(name: "slideshowVertex") else {
            throw GPUContextError.missingShaderFunction("slideshowVertex")
        }
        guard let fragment = gpu.library.makeFunction(name: "slideshowFragment") else {
            throw GPUContextError.missingShaderFunction("slideshowFragment")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Slideshow"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        pipeline = try gpu.device.makeRenderPipelineState(descriptor: descriptor)

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let black = gpu.device.makeTexture(descriptor: d) else { throw ExportError.readbackFailed }
        var pixel: [UInt8] = [0, 0, 0, 255]
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &pixel, bytesPerRow: 4)
        self.black = black
    }

    static func uniforms(for frame: SlideshowFrame, viewSize: CGSize) -> SlideshowUniforms {
        let t = SlideshowEasing.easeInOut(frame.progress)
        let rects = SlideshowGeometry.rects(transition: frame.transition, progress: CGFloat(t),
                                           direction: frame.direction, fromImage: frame.from?.pixelSize,
                                           toImage: frame.to?.pixelSize, viewSize: viewSize)
        func vector(_ rect: CGRect?) -> SIMD4<Float> {
            guard let rect, rect.width > 0, rect.height > 0 else { return SIMD4(0, 0, 1, 1) }
            return SIMD4(Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height))
        }
        var u = SlideshowUniforms()
        u.fromRect = vector(rects.from)
        u.toRect = vector(rects.to)
        u.info = SIMD4(frame.from == nil || rects.from == nil ? 0 : 1, frame.to == nil || rects.to == nil ? 0 : 1, 0, 0)
        // A slide at rest (or a cut) shows only the new slide.
        let settled = !frame.transition.animates || t >= 1
        u.params = SIMD4(settled ? 1 : t, settled ? 0 : frame.transition.shaderKind,
                         frame.direction == .backward ? 1 : 0, 0)
        u.view = SIMD4(Float(viewSize.width), Float(viewSize.height), 0, 0)
        return u
    }

    /// Draws `frame` and presents it. Returns at once; the GPU finishes
    /// asynchronously.
    public func draw(_ frame: SlideshowFrame, to drawable: CAMetalDrawable) {
        guard let commands = encode(frame, into: drawable.texture) else { return }
        commands.present(drawable)
        commands.commit()
    }

    /// Draws into a texture (render-target usage, `pixelFormat`) and waits,
    /// for tests and snapshots.
    public func draw(_ frame: SlideshowFrame, into target: MTLTexture) {
        guard let commands = encode(frame, into: target) else { return }
        commands.commit()
        commands.waitUntilCompleted()
    }

    private func encode(_ frame: SlideshowFrame, into target: MTLTexture) -> MTLCommandBuffer? {
        var u = Self.uniforms(for: frame, viewSize: CGSize(width: target.width, height: target.height))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let commands = gpu.commandQueue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        commands.label = "Slideshow"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&u, length: MemoryLayout<SlideshowUniforms>.stride, index: 0)
        encoder.setFragmentTexture(frame.from?.texture ?? black, index: 0)
        encoder.setFragmentTexture(frame.to?.texture ?? black, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return commands
    }
}

extension Exporter {
    /// A rendered (display-encoded) texture rotated, cropped and shrunk to
    /// at most `maxLongEdge`, as an 8-bit texture the GPU keeps: the
    /// exporter's own passes (the linear-light Lanczos resize when the size
    /// changes), without the copy to the CPU a file needs.
    public func screenTexture(from texture: MTLTexture, rotation: ImageRotation, crop: CropParameters,
                              maxLongEdge: Int?) throws -> SlideTexture {
        let frame = CropFrame(sensorSize: CGSize(width: texture.width, height: texture.height),
                              crop: crop, rotation: rotation)
        let (w, h) = Self.outputSize(frame: frame, maxLongEdge: maxLongEdge)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h,
                                                                  mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let dest = gpu.device.makeTexture(descriptor: descriptor) else { throw ExportError.readbackFailed }
        if (w, h) != Self.outputSize(frame: frame, maxLongEdge: nil) {
            try resample(texture, frame: frame, into: dest, sourceIsEncoded: true, encode: true)
            return SlideTexture(texture: dest)
        }
        guard let commands = gpu.commandQueue.makeCommandBuffer(),
              let encoder = commands.makeComputeCommandEncoder() else { throw ExportError.readbackFailed }
        let pso = gpu.packForExportPSO
        encoder.setComputePipelineState(pso)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(dest, index: 1)
        var map = frame.normalizedSamplingMap()
        encoder.setBytes(&map, length: MemoryLayout<simd_float3x2>.size, index: 0)
        let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (w + tw - 1) / tw, height: (h + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status != .error else { throw ExportError.readbackFailed }
        return SlideTexture(texture: dest)
    }
}
