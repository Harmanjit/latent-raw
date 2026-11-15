import Foundation
import Metal
import simd

// The tone equalizer inside a mask (wave 4): a local adjustment carries its
// own nine band gains, so only the sky (say) is equalized.
//
// The bands are read from the *global* tone equalizer's mask (the
// guided-filtered log luminance, ToneEqualizerStage.swift), with its mask
// exposure, contrast, smoothing and edge settings, so a band in a mask moves
// the same tones the panel's band of that stop does. Two GPU steps:
//
//   1. `toneEqLocalGains` (ToneEqualizer.metal), right after the global
//      tone equalizer and from the same input: per pixel, each mask's gain
//      in EV at that pixel's smoothed brightness, into two RGBA textures
//      (masks 0-3 and 4-7). Its own kernel, so the global stage's kernel
//      and output are untouched.
//   2. The colour kernel (ColorPipeline.metal), in its local-adjustment
//      loop: scales the working colour by 2^(gain × mask), like the mask's
//      Exposure slider, so the gain lands exactly where the mask is
//      (ranges and components included, which only that kernel builds)
//      and is blended like the mask's other sliders. The textures sit in
//      free texture slots and the flag in `MaskOverlayParamsGPU`'s spare
//      word, because the kernel has no buffer slot left.
//
// With no mask using it the first step never runs, the flag stays 0 and the
// colour kernel reads nothing new, so every existing edit renders exactly
// as before.

extension LocalAdjustment {
    /// Whether any of the mask's tone equalizer bands is moved.
    public var hasToneEqualizerBands: Bool {
        toneEqualizerBands?.contains { $0 != 0 } == true
    }

    /// Whether a render has tone-equalizer work to do for this mask: bands
    /// moved, the mask shown and with some amount.
    public var wantsToneEqualizer: Bool { !hidden && amount > 0 && hasToneEqualizerBands }

    /// Band `index`'s gain in EV, 0 when unset.
    public func toneEqualizerBand(_ index: Int) -> Float {
        guard let bands = toneEqualizerBands, bands.indices.contains(index) else { return 0 }
        return bands[index]
    }

    /// Sets band `index` (clamped to `ToneEqualizer.gainRange`), dropping
    /// the bands back to nil once every one is 0, so a mask whose bands
    /// were moved and put back stores nothing.
    public mutating func setToneEqualizerBand(_ index: Int, to value: Float) {
        guard (0..<ToneEqualizer.bandCount).contains(index) else { return }
        var bands = toneEqualizerBands ?? Array(repeating: 0, count: ToneEqualizer.bandCount)
        if bands.count < ToneEqualizer.bandCount {
            bands += Array(repeating: 0, count: ToneEqualizer.bandCount - bands.count)
        }
        let r = ToneEqualizer.gainRange
        bands[index] = value.isFinite ? min(max(value, r.lowerBound), r.upperBound) : 0
        toneEqualizerBands = Self.sanitizedToneEqualizerBands(bands)
    }

    /// Bands from a file made safe: exactly nine, each clamped to the gain
    /// range (a non-finite value read as 0), nil when every one is 0.
    static func sanitizedToneEqualizerBands(_ bands: [Float]?) -> [Float]? {
        guard let bands else { return nil }
        let clean = ToneEqualizer(bands: bands).sanitized.bands
        return clean.contains { $0 != 0 } ? clean : nil
    }

    /// The tone equalizer this mask applies: its own bands with the global
    /// equalizer's mask settings (`global`), or nil when it has none.
    func localToneEqualizer(global: ToneEqualizer) -> ToneEqualizer? {
        guard wantsToneEqualizer, let bands = toneEqualizerBands else { return nil }
        var equalizer = global
        equalizer.bands = bands
        return equalizer.sanitized
    }
}

/// The per-mask gain pass (step 1 above).
enum LocalToneEqualizerStage {
    /// Mirror of `ToneEqLocalParams` in ToneEqualizer.metal.
    struct Params {
        var yRow: SIMD4<Float>        // xyz: luminance row, w: exposure (EV)
        var placement: SIMD4<Float>   // xy: tile origin (sensor px), z: bin span
        var sensorSize: SIMD4<Float>  // xy: sensor size, z: exposure compensation, w: contrast factor
        var table: SIMD4<Float>       // y: table low EV, z: table high EV, w: entries
        var active: SIMD4<UInt32>     // x: bit k set when mask k has a table
    }

    /// The masks (by index, only the first `LocalAdjustment.maximumCount`)
    /// with bands to apply, and their gain tables back to back: one table
    /// of `ToneEqualizer.lutCount` entries per slot, zeros for a mask
    /// without. nil when no mask has any.
    static func tables(locals: [LocalAdjustment], global: ToneEqualizer) -> (active: UInt32, tables: [Float])? {
        let slots = LocalAdjustment.maximumCount, n = ToneEqualizer.lutCount
        var active: UInt32 = 0
        var tables = [Float](repeating: 0, count: slots * n)
        for (k, local) in locals.prefix(slots).enumerated() {
            guard let equalizer = local.localToneEqualizer(global: global) else { continue }
            active |= 1 << UInt32(k)
            tables.replaceSubrange((k * n)..<((k + 1) * n), with: equalizer.gainTable())
        }
        return active == 0 ? nil : (active, tables)
    }

    /// Whether any mask a render applies has bands, so the global mask
    /// must be made even with the panel's own bands at 0.
    static func wanted(_ parameters: EditParameters) -> Bool {
        parameters.locals.prefix(LocalAdjustment.maximumCount).contains(where: \.wantsToneEqualizer)
    }

    /// Encodes the gain pass over `input` (camera RGB as the global stage
    /// read it) and returns the two gain textures, the size of `input`.
    static func encode(input: MTLTexture, coefficients: MTLTexture, active: UInt32, tables: [Float],
                       global: ToneEqualizer, yRow: SIMD3<Float>, exposureEV: Float,
                       placement: ToneEqualizerStage.Placement, session: ImageSession,
                       gpu: GPUContext, commandBuffer: MTLCommandBuffer) throws -> (MTLTexture, MTLTexture) {
        let a = try session.texture(width: input.width, height: input.height, pixelFormat: .rgba16Float,
                                    role: .toneEqualizerLocalA)
        let b = try session.texture(width: input.width, height: input.height, pixelFormat: .rgba16Float,
                                    role: .toneEqualizerLocalB)
        // 8 × 256 floats is past setBytes' 4 KB, so a buffer of its own.
        guard let buffer = gpu.device.makeBuffer(bytes: tables, length: tables.count * 4,
                                                 options: .storageModeShared) else {
            throw RenderError.gpuBufferAllocationFailed
        }
        var params = Params(
            yRow: SIMD4(yRow, exposureEV),
            placement: SIMD4(placement.tileOrigin.x, placement.tileOrigin.y, placement.binSpan, 0),
            sensorSize: SIMD4(placement.sensorSize.x, placement.sensorSize.y,
                              global.exposureCompensation, global.contrastFactor),
            table: SIMD4(0, ToneEqualizer.lutRange.lowerBound, ToneEqualizer.lutRange.upperBound,
                         Float(ToneEqualizer.lutCount)),
            active: SIMD4(active, 0, 0, 0))
        let pso = try gpu.lazyPipeline(.toneEqLocalGains)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw RenderError.commandBufferFailed }
        encoder.setComputePipelineState(pso)
        encoder.setTexture(input, index: 0)
        encoder.setTexture(coefficients, index: 1)
        encoder.setTexture(a, index: 2)
        encoder.setTexture(b, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.setBuffer(buffer, offset: 0, index: 1)
        ToneEqualizerStage.dispatch(encoder, pso: pso, width: input.width, height: input.height)
        encoder.endEncoding()
        return (a, b)
    }
}
