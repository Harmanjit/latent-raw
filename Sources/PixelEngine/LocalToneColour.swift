import Foundation
import Metal
import simd

// The tone curve, Point Colour and grain inside a mask. They run in the
// local detail stage (LocalDetailStage.swift, Shaders/LocalDetail.metal),
// on the display-referred picture, through the mask the colour kernel
// writes for that stage: the colour kernel has no argument slots left,
// and the stage already has each mask per pixel. Curve and Point Colour
// work on the gamma 2.2 scale the global curve and Point Colour use, so
// a curve drawn in a mask means what the same curve means globally.

extension LocalAdjustment {
    /// Point Colour swatches a mask can hold.
    public static let maximumPointColours = 4

    /// The master curve when it bends.
    var activeCurve: ToneCurve? { curve.flatMap { $0.isIdentity ? nil : $0 } }
    /// The red, green and blue curves when any bends.
    var activeChannelCurves: RGBCurves? { channelCurves.flatMap { $0.isIdentity ? nil : $0 } }
    /// The swatches that change something.
    var activePointColours: [PointColour] {
        Array(pointColours.prefix(Self.maximumPointColours)).filter(\.isActive)
    }

    /// Whether the curve, Point Colour or grain has anything to do.
    public var wantsToneColourStage: Bool {
        activeCurve != nil || activeChannelCurves != nil || !activePointColours.isEmpty || grain?.isActive == true
    }

    /// The flag word the shader reads in `detail.w`.
    var toneColourFlags: UInt32 {
        (activeCurve != nil ? LocalToneColour.flagCurve : 0)
            | (activeChannelCurves != nil ? LocalToneColour.flagChannelCurves : 0)
            | (activePointColours.isEmpty ? 0 : LocalToneColour.flagPointColour)
            | (grain?.isActive == true ? LocalToneColour.flagGrain : 0)
    }
}

enum LocalToneColour {
    static let flagCurve: UInt32 = 1
    static let flagChannelCurves: UInt32 = 2
    static let flagPointColour: UInt32 = 4
    static let flagGrain: UInt32 = 8

    /// Floats per mask slot in the curve table: master, red, green, blue.
    static let tableStride = 4 * ToneCurve.lutSize

    /// Every slot's curves end to end, in slot order, identity where a
    /// mask has none; nil when no mask in the stage has a curve.
    static func curveTable(for locals: [LocalAdjustment], slots: [Int: Int]) -> [Float]? {
        guard slots.keys.contains(where: { locals[$0].activeCurve != nil || locals[$0].activeChannelCurves != nil })
        else { return nil }
        let identity = ToneCurve.identity.lookupTable()
        var table = [Float](repeating: 0, count: slots.count * tableStride)
        for (index, slot) in slots {
            let local = locals[index]
            let master = local.activeCurve?.lookupTable() ?? identity
            let rgb = local.activeChannelCurves?.lookupTable() ?? identity + identity + identity
            let start = slot * tableStride
            table.replaceSubrange(start..<start + ToneCurve.lutSize, with: master)
            table.replaceSubrange(start + ToneCurve.lutSize..<start + tableStride, with: rgb)
        }
        return table
    }

    /// The grain's values for the shader: amount, grain size in sensor
    /// pixels and roughness.
    static func grain(_ grain: Grain?, shortSide: Float) -> SIMD3<Float> {
        guard let g = grain?.sanitized, g.isActive else { return .zero }
        return SIMD3(g.amount, g.cellSensorPixels(shortSide: shortSide), g.roughness)
    }
}

/// Mirror of `LocalDetailFrame` in LocalDetail.metal: where the render
/// sits on the sensor, so local grain is fixed to the picture as the
/// global grain is.
struct LocalDetailFrameGPU {
    var tileOrigin: SIMD2<Float>
    var binSpan: Float
    var seed: UInt32
}
