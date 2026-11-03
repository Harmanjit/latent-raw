import Foundation
import Metal
import simd

/// Mirror of `ColourExtras` in ColorPipeline.metal: float4-sized fields
/// only, so Swift and Metal lay it out the same way.
struct ColourExtrasGPU {
    var info = SIMD4<UInt32>(0, 0, 0, 0)
    var basics = SIMD4<Float>(0, 0.5, 0, 0)
    var bwMix0 = SIMD4<Float>(repeating: 0)
    var bwMix1 = SIMD4<Float>(repeating: 0)
    var shadows = SIMD4<Float>(repeating: 0)
    var midtones = SIMD4<Float>(repeating: 0)
    var highlights = SIMD4<Float>(repeating: 0)
    var global = SIMD4<Float>(repeating: 0)
    var pointTarget = ColourExtrasGPU.Eight()
    var pointShift = ColourExtrasGPU.Eight()

    /// A fixed array of eight, as the Metal struct has.
    struct Eight {
        var v = (SIMD4<Float>(), SIMD4<Float>(), SIMD4<Float>(), SIMD4<Float>(),
                 SIMD4<Float>(), SIMD4<Float>(), SIMD4<Float>(), SIMD4<Float>())

        subscript(i: Int) -> SIMD4<Float> {
            get { withUnsafeBytes(of: v) { $0.loadUnaligned(fromByteOffset: i * 16, as: SIMD4<Float>.self) } }
            set { withUnsafeMutableBytes(of: &v) { $0.storeBytes(of: newValue, toByteOffset: i * 16, as: SIMD4<Float>.self) } }
        }
    }

    init() {}

    init(_ c: ColourControls, splitBalance: Float) {
        info.x = c.gpuFlags
        guard info.x != 0 else { return }
        let g = c.grading
        basics = SIMD4(c.saturation, g.blending, splitBalance, c.calibration.shadowTint)
        let mix = c.blackAndWhite.mix.count == 8 ? c.blackAndWhite.mix : BlackAndWhite.neutralMix
        bwMix0 = SIMD4(mix[0], mix[1], mix[2], mix[3])
        bwMix1 = SIMD4(mix[4], mix[5], mix[6], mix[7])
        shadows = SIMD4(0, 0, g.shadowLuminance, 0)
        highlights = SIMD4(0, 0, g.highlightLuminance, 0)
        midtones = SIMD4(g.midtones.hue, g.midtones.saturation, g.midtones.luminance, 0)
        global = SIMD4(g.global.hue, g.global.saturation, g.global.luminance, 0)
        let points = c.pointColours.prefix(PointColour.maximumCount)
        info.y = UInt32(points.count)
        for (i, pc) in points.enumerated() {
            pointTarget[i] = SIMD4(pc.hue, pc.saturation, pc.value, pc.range)
            pointShift[i] = SIMD4(pc.hueShift, pc.saturationShift, pc.luminanceShift, pc.variance)
        }
    }
}

extension RenderPipeline {
    /// The colour controls' uniforms, at index 30. Always bound (the kernel
    /// reads the flag word), but with every control neutral that word is 0
    /// and the kernel runs none of their code.
    func encodeColourControls(_ encoder: MTLComputeCommandEncoder, parameters: EditParameters) {
        var extras = ColourExtrasGPU(parameters.colour, splitBalance: parameters.splitToning.balance)
        encoder.setBytes(&extras, length: MemoryLayout<ColourExtrasGPU>.stride, index: 30)
    }

    /// The camera-to-working matrix with Calibration's primaries applied
    /// after it, in the working space; the matrix itself when they're not
    /// moved, so an uncalibrated edit uses the same numbers as before.
    static func calibrated(_ cameraToWorking: simd_float3x3, _ calibration: Calibration) -> simd_float3x3 {
        calibration.movesPrimaries ? calibration.matrix * cameraToWorking : cameraToWorking
    }
}
