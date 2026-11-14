import Foundation
import Metal
import simd
import RawCore

// MARK: - The method

/// How Highlight Reconstruction rebuilds clipped channels.
///
/// `blend` is what Latent has always done (ColorPipeline.metal's
/// `reconstructHighlights`): each channel past the threshold is pulled
/// towards the brightest one, which takes the magenta cast out of a blown
/// highlight by making it neutral. `inpaintOpposed` is darktable's
/// "inpaint opposed": a clipped channel is rebuilt from the two channels
/// opposite it, scaled by the colour of the unclipped pixels just around
/// the clipped areas, so a blown sky or face keeps a hint of its colour
/// instead of going white.
///
/// The edit stores the method only when it isn't `blend`
/// (`EditStack.Highlights.method`), so every edit made before it existed
/// keeps rendering exactly as it did. It is never the default, which is
/// why it needs no new process version.
public enum HighlightReconstructionMethod: String, CaseIterable, Sendable {
    case blend
    case inpaintOpposed

    public var displayName: String {
        switch self {
        case .blend: return "Blend (neutral)"
        case .inpaintOpposed: return "Inpaint Opposed (keeps colour)"
        }
    }
}

// MARK: - The whole-image estimate

/// What the inpaint stage learns from the whole frame: the summed raw
/// values, per channel, of the unclipped pixels in a ring around every
/// clipped area. The ring's colour is what the clipped pixels are taken
/// to have been, so each clipped channel is rebuilt as the mean of the
/// other two times that colour's ratio (`ratio(multipliers:)`).
///
/// Sums rather than a ratio, and in raw units before white balance, so one
/// estimate serves every white balance: the ring is the same pixels
/// whatever the multipliers (a photosite clips at the sensor's white either
/// way), and the multipliers scale each sum by a constant. Made once per
/// threshold from a quarter-scale pass over the whole sensor plane, so a
/// tile, the preview and an export all rebuild with the same colour.
public struct HighlightInpaintEstimate: Equatable, Sendable {
    /// Summed R, G and B of the ring, in units of the sensor's white.
    public var sums: SIMD3<Double>
    /// How many quarter-scale pixels the ring has.
    public var ringCount: Int
    /// How many quarter-scale pixels were clipped.
    public var clippedCount: Int

    public static let empty = HighlightInpaintEstimate(sums: .zero, ringCount: 0, clippedCount: 0)

    /// Fewer ring pixels than this and the colour is mostly noise: the
    /// stage falls back to a neutral ratio (clipped channels rebuilt to the
    /// mean of the others, in white-balanced values).
    static let minimumRing = 16

    /// The ratio a clipped channel is rebuilt with, in the white-balanced
    /// values the stage works on: the ring's channel over the mean of its
    /// other two. Neutral (1, 1, 1) without a usable ring.
    public func ratio(multipliers m: SIMD3<Float>) -> SIMD3<Float> {
        guard ringCount >= Self.minimumRing else { return SIMD3(repeating: 1) }
        let v = SIMD3<Double>(Double(m.x), Double(m.y), Double(m.z)) * sums
        let opposite = SIMD3<Double>(v.y + v.z, v.x + v.z, v.x + v.y) * 0.5
        guard opposite.min() > 0, v.min() > 0 else { return SIMD3(repeating: 1) }
        let r = v / opposite
        return simd_clamp(SIMD3<Float>(Float(r.x), Float(r.y), Float(r.z)),
                          SIMD3(repeating: 0.1), SIMD3(repeating: 10))
    }
}

public enum HighlightInpaint {
    /// Sensor photosites per estimate pixel on each axis: a quarter-scale
    /// pass, one Bayer quad read from each 4x4 block.
    static let blockSpan = 4
    /// How far, in estimate pixels (four photosites each), the ring
    /// reaches out from a clipped area. The pixels right beside one are
    /// left out of it.
    static let ringRadius = 3
    /// Ring pixels darker than this (their brightest channel, in units of
    /// the sensor's white) are left out: a clipped area's edge against a
    /// dark background says nothing about the clipped colour.
    static let ringFloor: Float = 0.2

    /// The estimate from a Bayer sensor plane, `width x height` photosites
    /// of the given order and levels. A photosite counts as clipped at
    /// `threshold` of white; a block is clipped when any of its quad's
    /// photosites is.
    public static func estimate(samples: UnsafeBufferPointer<UInt16>, width: Int, height: Int, order: UInt8,
                                blackLevel: Float, whiteLevel: Float, threshold: Float) -> HighlightInpaintEstimate {
        let bw = width / blockSpan, bh = height / blockSpan
        guard bw > 2, bh > 2, samples.count >= width * height else { return .empty }
        let range = max(whiteLevel - blackLevel, 1)
        let clipAt = min(max(threshold, 0.5), 1)

        // The colour index (0 R, 1 G, 2 B) of each photosite of the quad.
        var quadColour = [Int](repeating: 1, count: 4)
        for i in 0..<4 {
            let c = Int(order >> UInt8(i * 2)) & 3
            quadColour[i] = c == 3 ? 1 : c
        }

        var values = [SIMD3<Float>](repeating: .zero, count: bw * bh)
        var clipped = [UInt8](repeating: 0, count: bw * bh)
        for by in 0..<bh {
            let y = by * blockSpan
            for bx in 0..<bw {
                let x = bx * blockSpan
                var sum = SIMD3<Float>.zero
                var count = SIMD3<Float>.zero
                var isClipped = false
                for i in 0..<4 {
                    let raw = Float(samples[(y + (i >> 1)) * width + x + (i & 1)])
                    let n = max(0, (raw - blackLevel) / range)
                    if n >= clipAt { isClipped = true }
                    sum[quadColour[i]] += n
                    count[quadColour[i]] += 1
                }
                values[by * bw + bx] = sum / simd_max(count, SIMD3(repeating: 1))
                clipped[by * bw + bx] = isClipped ? 1 : 0
            }
        }

        // The ring: within `ringRadius` of a clipped pixel, but not next to
        // one, where a soft edge still mixes the clipped colour in.
        let outer = dilated(clipped, width: bw, height: bh, radius: ringRadius)
        let inner = dilated(clipped, width: bw, height: bh, radius: 1)
        var sums = SIMD3<Double>.zero
        var ringCount = 0
        var clippedCount = 0
        for i in 0..<(bw * bh) {
            if clipped[i] != 0 { clippedCount += 1; continue }
            guard outer[i] != 0, inner[i] == 0 else { continue }
            let v = values[i]
            guard v.max() >= ringFloor else { continue }
            sums += SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
            ringCount += 1
        }
        return HighlightInpaintEstimate(sums: sums, ringCount: ringCount, clippedCount: clippedCount)
    }

    /// A square dilation of a 0/1 mask: rows, then columns.
    static func dilated(_ mask: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        var across = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                for dx in max(0, x - r)...min(w - 1, x + r) where mask[y * w + dx] != 0 { across[y * w + x] = 1; break }
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                for dy in max(0, y - r)...min(h - 1, y + r) where across[dy * w + x] != 0 { out[y * w + x] = 1; break }
            }
        }
        return out
    }

    /// The estimate for `session`'s sensor plane at `threshold`, made once
    /// and kept on the session. nil for a source that isn't a Bayer raw.
    static func estimate(for session: ImageSession, threshold: Float) -> HighlightInpaintEstimate? {
        guard case .bayer(let order) = session.file.summary.cfaPattern,
              let samples = session.file.rawSensorPlane() else { return nil }
        if let known = session.highlightInpaintEstimates[threshold] { return known }
        let s = session.file.summary
        let made = estimate(samples: samples, width: s.rawWidth, height: s.rawHeight, order: order,
                            blackLevel: s.blackLevel, whiteLevel: s.whiteLevel, threshold: threshold)
        // A handful of thresholds at most (the slider's stops while it is
        // dragged); a long drag shouldn't keep every one.
        if session.highlightInpaintEstimates.count > 16 { session.highlightInpaintEstimates.removeAll() }
        session.highlightInpaintEstimates[threshold] = made
        return made
    }
}

// MARK: - The stage

/// Mirror of `HighlightInpaintParams` in HighlightInpaint.metal.
struct HighlightInpaintParamsGPU {
    var clipLevel: SIMD4<Float>
    var ratio: SIMD4<Float>
    var threshold: Float
    var amount: Float
    var padding = SIMD2<Float>(0, 0)
}

/// Stage 6a (RenderPipeline): Inpaint Opposed, on camera RGB after the
/// spot removal and before the flat-field and lens stages, so the clip
/// levels it tests against still hold (the lens stage's vignetting and
/// the flat field scale pixels away from them). While it runs, the colour
/// kernel's blend is switched off (`blendStrength`), so the two methods
/// never stack.
enum HighlightInpaintStage {
    /// Whether the stage runs for this render: the method chosen, Recovery
    /// above 0 and a Bayer raw. A linear source (a merge, a JPEG) keeps the
    /// blend: its clip level isn't a sensor's.
    static func isActive(_ p: EditParameters, session: ImageSession) -> Bool {
        p.highlightMethod == .inpaintOpposed && p.highlightRecovery > 0 && session.sourceKind == .bayer
    }

    /// The Recovery the colour kernel's blend gets: none while inpaint runs.
    static func blendStrength(_ p: EditParameters, session: ImageSession) -> Float {
        isActive(p, session: session) ? 0 : p.highlightRecovery
    }

    static func encode(input: MTLTexture, session: ImageSession, multipliers: SIMD4<Float>,
                       parameters p: EditParameters, preview: Bool,
                       gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        let estimate = HighlightInpaint.estimate(for: session, threshold: p.highlightThreshold) ?? .empty
        let m = SIMD3(multipliers.x, multipliers.y, multipliers.z)
        let clip = session.highlightClipLevel(multipliers: multipliers)
        let output = try session.texture(width: input.width, height: input.height, pixelFormat: .rgba16Float,
                                         role: preview ? .highlightInpaintPreview : .highlightInpaint)
        let pso = try gpu.lazyPipeline(.highlightInpaintOpposed)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        var params = HighlightInpaintParamsGPU(clipLevel: SIMD4(clip, 0), ratio: SIMD4(estimate.ratio(multipliers: m), 0),
                                               threshold: p.highlightThreshold, amount: min(max(p.highlightRecovery, 0), 1))
        encoder.setComputePipelineState(pso)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<HighlightInpaintParamsGPU>.stride, index: 0)
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (input.width + tw - 1) / tw, height: (input.height + th - 1) / th,
                                             depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        encoder.endEncoding()
        return output
    }
}
