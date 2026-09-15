import Foundation
import Metal
import QuartzCore
import simd
import Synchronization

/// One texture and where it belongs in sensor space.
public struct PresentLayer {
    public let texture: MTLTexture
    /// The sensor rectangle the texture covers.
    public let coverage: CGRect
    /// Pixels to trim from every edge before drawing. Full-resolution
    /// tiles set this to hide the demosaic's degraded border.
    public let inset: CGFloat
    /// The ceiling the pipeline rendered this texture to
    /// (`RenderOutput.headroom`). The presenter fits values up to it into
    /// whatever the screen can show at the moment of drawing.
    public let headroom: Float
    /// Different for every layer made. Renders reuse pooled textures, so a
    /// new image often arrives in the very texture object the last one
    /// used; the texture's identity can't tell a view there is something
    /// new to draw, but this can.
    public let generation: UInt64

    private static let generations = Atomic<UInt64>(0)

    public init(texture: MTLTexture, coverage: CGRect, inset: CGFloat = 0, headroom: Float = 1) {
        self.texture = texture
        self.coverage = coverage
        self.inset = inset
        self.headroom = max(1, headroom)
        self.generation = Self.generations.add(1, ordering: .relaxed).newValue
    }
}

/// The press-and-hold magnifier, as the presenter draws it: a circle at
/// `loupe.center` showing the image at `loupe.zoom` about that point, from
/// `tile` where it covers and from the base layer (softly) where it doesn't,
/// inside a thin ring.
public struct PresentMagnifier {
    public var loupe: ViewerInteraction.Magnifier
    /// Ring width in drawable pixels.
    public var ringWidth: CGFloat
    /// A full-resolution render of the area under the loupe, when one is ready.
    public var tile: PresentLayer?

    public init(loupe: ViewerInteraction.Magnifier, ringWidth: CGFloat, tile: PresentLayer?) {
        self.loupe = loupe
        self.ringWidth = ringWidth
        self.tile = tile
    }
}

/// The viewport's EDR decisions, as plain arithmetic so they can be tested
/// without a screen.
///
/// Two headrooms are in play. A screen's *potential* headroom is how far
/// above SDR white it could reach once some content asks for EDR; it
/// belongs to the display, not to its brightness setting. Its *current*
/// headroom is what it shows right now, which follows the brightness
/// slider and ramps up over a second or so after EDR content appears. The
/// pipeline renders to the potential one, so an edit looks the same at any
/// brightness and a brightness change never costs a render; the presenter
/// rolls the highlights off to the current one on every draw.
public enum DisplayHeadroom {
    /// The most the tone curve is ever given. A display that reports 16x
    /// headroom would otherwise render every clipped cloud as a
    /// searchlight; 4x is already very bright.
    public static let renderCeiling: Float = 4

    /// The headroom the pipeline renders the viewport to. Soft proofing
    /// overrides it with 1, since an EDR highlight can't be in the file
    /// being proofed.
    public static func rendered(potential: CGFloat, hdrDisplayEnabled: Bool) -> Float {
        guard hdrDisplayEnabled else { return 1 }
        return min(max(1, Float(potential)), renderCeiling)
    }

    /// Whether the layer should ask for EDR. EDR makes the display raise
    /// its backlight and dim everything else to match, which costs power,
    /// so it is on only while the image on screen was rendered with room
    /// above white and the screen can show some of it.
    public static func wantsExtendedDynamicRange(contentHeadroom: Float, potential: CGFloat) -> Bool {
        contentHeadroom > 1 && potential > 1
    }

    /// The headroom to draw for. Without EDR on the layer it is 1 whatever
    /// the screen says: the compositor would clip anything brighter.
    public static func presented(current: CGFloat, extendedDynamicRange: Bool) -> Float {
        extendedDynamicRange ? max(1, Float(current)) : 1
    }
}

/// The present kernel's highlight roll-off (`toneMapToHeadroom` in
/// Present.metal), copied line for line so its properties can be tested
/// without a GPU. Change both together.
public enum HeadroomToneMap {
    /// The value a pixel whose largest channel is `peak` is scaled to.
    public static func map(peak: Float, displayHeadroom: Float, contentHeadroom: Float) -> Float {
        if contentHeadroom <= displayHeadroom || peak <= 0 { return peak }
        let knee = displayHeadroom * 0.75
        if peak <= knee { return peak }
        let range = displayHeadroom - knee
        let x = (peak - knee) / range
        let xMax = (contentHeadroom - knee) / range
        let y = x * (1 + x / (xMax * xMax)) / (1 + x)
        return knee + range * min(y, 1)
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
/// The textures arrive as extended linear Display P3 rendered to some
/// headroom. The one display transform done here is fitting that headroom
/// into what the screen can show at this moment (see `DisplayHeadroom`).
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
        present(base: base, tile: tile, transform: transform,
                frame: CropFrame(sensorSize: sensorSize, rotation: rotation),
                to: drawable, backgroundLevel: backgroundLevel)
    }

    /// The general form: `frame` carries rotation, crop and straighten.
    /// `displayHeadroom` is what the screen shows above SDR white right now
    /// (1 without EDR); brighter content is rolled off to fit it.
    public func present(base: PresentLayer,
                         tile: PresentLayer?,
                         transform: ViewportTransform,
                         frame: CropFrame,
                         to drawable: CAMetalDrawable,
                         backgroundLevel: Float = 0.12,
                         displayHeadroom: Float = 1,
                         magnifier: PresentMagnifier? = nil) {
        guard let cmdBuffer = encode(base: base, tile: tile, transform: transform, frame: frame,
                                     into: drawable.texture, backgroundLevel: backgroundLevel,
                                     displayHeadroom: displayHeadroom, magnifier: magnifier) else { return }
        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    /// Encodes the present pass into `target` and returns the command
    /// buffer uncommitted. Split from `present` so tests can draw offscreen.
    func encode(base: PresentLayer,
                tile: PresentLayer?,
                transform: ViewportTransform,
                frame: CropFrame,
                into target: MTLTexture,
                backgroundLevel: Float,
                displayHeadroom: Float,
                magnifier: PresentMagnifier? = nil) -> MTLCommandBuffer? {
        let drawableSize = CGSize(width: target.width, height: target.height)
        let baseMap = transform.screenToTextureMap(coverage: base.coverage, frame: frame,
                                                   drawableSize: drawableSize)
        let (tileMap, tileSource) = Self.tilePlacement(tile, transform: transform, frame: frame,
                                                       drawableSize: drawableSize, fallback: baseMap)

        var flags: UInt32 = 0
        // Full-resolution layers show square pixels past 200%.
        if ViewerInteraction.samplesNearest(zoom: transform.zoom) { flags |= PresentFlags.tileNearest }
        var loupe = PresentLoupe(baseMap: baseMap, tileMap: tileMap, tileSource: tileSource,
                                 circle: SIMD4<Float>(0, 0, -1, 0))
        if let magnifier {
            let shown = magnifier.loupe.transform(in: transform, drawableSize: drawableSize)
            let loupeBase = shown.screenToTextureMap(coverage: base.coverage, frame: frame,
                                                     drawableSize: drawableSize)
            let (map, source) = Self.tilePlacement(magnifier.tile, transform: shown, frame: frame,
                                                   drawableSize: drawableSize, fallback: loupeBase)
            loupe = PresentLoupe(baseMap: loupeBase, tileMap: map, tileSource: source,
                                 circle: SIMD4<Float>(Float(magnifier.loupe.center.x), Float(magnifier.loupe.center.y),
                                                      Float(magnifier.loupe.radius), Float(magnifier.ringWidth)))
            flags |= PresentFlags.magnifier
            if magnifier.tile != nil { flags |= PresentFlags.magnifierHasTile }
            if ViewerInteraction.samplesNearest(zoom: magnifier.loupe.zoom) { flags |= PresentFlags.magnifierNearest }
        }

        // The screen's headroom, then the ceiling each layer was rendered to.
        let headrooms = SIMD4<Float>(max(1, displayHeadroom), base.headroom, tile?.headroom ?? 1,
                                     magnifier?.tile?.headroom ?? 1)
        return draw(base: base.texture, baseMap: baseMap,
                    tile: tile?.texture, tileMap: tileMap, tileSource: tileSource,
                    loupeTile: magnifier?.tile?.texture, loupe: loupe, flags: flags,
                    into: target, backgroundLevel: backgroundLevel, headrooms: headrooms)
    }

    /// A full-resolution layer's screen-to-texture map, and the part of the
    /// texture to draw from (its inset border trimmed).
    private static func tilePlacement(_ tile: PresentLayer?, transform: ViewportTransform, frame: CropFrame,
                                      drawableSize: CGSize,
                                      fallback: simd_float3x2) -> (simd_float3x2, SIMD4<Float>) {
        guard let tile else { return (fallback, SIMD4<Float>(0, 0, 1, 1)) }
        let shown = tile.coverage.insetBy(dx: tile.inset, dy: tile.inset)
        let map = transform.screenToTextureMap(coverage: shown, frame: frame, drawableSize: drawableSize)
        let w = Float(tile.texture.width), h = Float(tile.texture.height)
        let i = Float(tile.inset)
        return (map, SIMD4<Float>(i / w, i / h, (w - 2 * i) / w, (h - 2 * i) / h))
    }

    /// Bits of the kernel's `flags` argument (Present.metal).
    private enum PresentFlags {
        static let tileNearest: UInt32 = 1 << 0
        static let magnifier: UInt32 = 1 << 1
        static let magnifierHasTile: UInt32 = 1 << 2
        static let magnifierNearest: UInt32 = 1 << 3
    }

    /// The magnifier's placement, laid out as the kernel's `Loupe` struct.
    private struct PresentLoupe {
        var baseMap: simd_float3x2
        var tileMap: simd_float3x2
        var tileSource: SIMD4<Float>
        /// Centre x, y, radius (negative: none) and ring width, in drawable pixels.
        var circle: SIMD4<Float>
    }

    private func draw(base: MTLTexture, baseMap: simd_float3x2,
                      tile: MTLTexture?, tileMap: simd_float3x2, tileSource: SIMD4<Float>,
                      loupeTile: MTLTexture?, loupe: PresentLoupe, flags: UInt32,
                      into target: MTLTexture, backgroundLevel: Float,
                      headrooms: SIMD4<Float>) -> MTLCommandBuffer? {
        guard let cmdBuffer = gpu.commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(gpu.presentPSO)
        encoder.setTexture(base, index: 0)
        // Metal requires every declared texture slot to be bound, even if
        // the kernel won't read it this time.
        encoder.setTexture(tile ?? base, index: 1)
        encoder.setTexture(target, index: 2)

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
        var headroomsV = headrooms
        encoder.setBytes(&headroomsV, length: MemoryLayout<SIMD4<Float>>.size, index: 5)
        encoder.setTexture(loupeTile ?? base, index: 3)
        var loupeV = loupe
        encoder.setBytes(&loupeV, length: MemoryLayout<PresentLoupe>.stride, index: 6)
        var flagsV = flags
        encoder.setBytes(&flagsV, length: 4, index: 7)

        let pso = gpu.presentPSO
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        let groups = MTLSize(width: (target.width + tw - 1) / tw,
                              height: (target.height + th - 1) / th,
                              depth: 1)
        encoder.dispatchThreadgroups(groups,
                                      threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        return cmdBuffer
    }
}
