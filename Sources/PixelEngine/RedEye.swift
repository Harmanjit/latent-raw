import Foundation
import CoreGraphics
import Metal
import simd
import ColorKit

/// One red-eye correction: a circle around a pupil, inside which pixels
/// that are flash-red become a dark neutral pupil.
///
/// Stored like a heal patch, in normalized sensor coordinates and applied
/// in camera space before the lens stage, so it stays on the eye through
/// crop, straighten, rotation and zoom. Only red pixels change: the iris,
/// the catchlight and the skin inside the circle keep their colour, so a
/// generous circle is harmless.
///
/// A Pet Eye spot (`kind == .pet`) works differently: an animal's eye
/// glows green, yellow or white from the tapetum behind the retina, not
/// red, so no colour test can find it. The circle is the pupil, and
/// everything inside it becomes a dark pupil, with an optional catchlight.
public struct RedEyeSpot: Equatable, Sendable, Codable, Identifiable {
    /// A person's red eye, or an animal's glowing one.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case human, pet
    }

    public var id: UUID
    public var centre: SIMD2<Float>
    /// Fraction of the sensor's short side.
    public var radius: Float
    /// 0 (no change) … 1.
    public var strength: Float
    /// Nil for a person's red eye, which is every spot an older build
    /// wrote, so those encode exactly as before.
    public var kind: Kind?
    /// Pet Eye's added catchlight: the direction from the pupil's centre
    /// to the highlight, a unit vector in sensor pixels (the app points it
    /// up and to the left on screen, whatever the camera's orientation).
    /// Nil for none, and always nil on a red-eye spot.
    public var catchlight: SIMD2<Float>?

    public static let defaultRadius: Float = 0.006
    /// Like heal patches: more is never a real photo's need.
    public static let maximumCount = 32

    public init(id: UUID = UUID(), centre: SIMD2<Float>, radius: Float = defaultRadius, strength: Float = 1,
                kind: Kind? = nil, catchlight: SIMD2<Float>? = nil) {
        self.id = id
        self.centre = centre
        self.radius = radius
        self.strength = strength
        self.kind = kind == .human ? nil : kind
        self.catchlight = kind == .pet ? catchlight : nil
    }

    public var isPet: Bool { kind == .pet }

    /// The catchlight direction a render can use: unit length, or nil when
    /// there is none, the spot is a red-eye one, or the vector is unusable.
    public var catchlightDirection: SIMD2<Float>? {
        guard isPet, let v = catchlight, v.x.isFinite, v.y.isFinite else { return nil }
        let length = simd_length(v)
        guard length > 1e-6 else { return nil }
        return v / length
    }

    /// Nothing to do: no size, no strength, or a non-finite centre.
    public var isIdentity: Bool {
        !(radius > 0) || !(strength > 0) || !centre.x.isFinite || !centre.y.isFinite
    }

    /// The spot as a render can trust it, whatever wrote the sidecar: the
    /// centre within a sensor's width of the sensor, a radius of at most
    /// half the short side and a strength in 0…1. Nil when a number isn't
    /// finite. A spot the app made comes back unchanged.
    public var sanitized: RedEyeSpot? {
        guard centre.x.isFinite, centre.y.isFinite, radius.isFinite, strength.isFinite else { return nil }
        var spot = self
        spot.centre = simd_clamp(centre, SIMD2(repeating: HealPatch.coordinateRange.lowerBound),
                                 SIMD2(repeating: HealPatch.coordinateRange.upperBound))
        spot.radius = min(max(radius, 0), 0.5)
        spot.strength = min(max(strength, 0), 1)
        if spot.kind == .human { spot.kind = nil }
        spot.catchlight = spot.catchlightDirection
        return spot
    }

    public func radiusPixels(sensorSize s: CGSize) -> CGFloat {
        CGFloat(radius) * min(s.width, s.height)
    }

    /// Sensor-pixel bounding box of the circle.
    public func bounds(sensorSize s: CGSize) -> CGRect {
        let r = radiusPixels(sensorSize: s)
        return CGRect(x: CGFloat(centre.x) * s.width - r, y: CGFloat(centre.y) * s.height - r,
                      width: 2 * r, height: 2 * r)
    }

    private enum CodingKeys: String, CodingKey { case id, centre, radius, strength, kind, catchlight }

    /// Lenient, like the lens block: a spot missing a key (another build's,
    /// or a hand-edited sidecar) loads with that key's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        centre = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .centre) ?? SIMD2(0.5, 0.5)
        radius = try c.decodeIfPresent(Float.self, forKey: .radius) ?? Self.defaultRadius
        strength = try c.decodeIfPresent(Float.self, forKey: .strength) ?? 1
        // A kind this build doesn't know reads as red-eye, not as a failure
        // to load the whole edit.
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? nil
        catchlight = try c.decodeIfPresent(SIMD2<Float>.self, forKey: .catchlight)
    }
}

/// The numbers red-eye removal runs on, shared by RedEye.metal and the
/// Auto button's check that an eye really is red. Measured in linear
/// Display P3, where minivu tuned them.
public enum RedEyeTuning {
    /// Redness (red over the larger of green and blue) where the pupil
    /// mask starts, and where it is full. A brown iris measures about 3
    /// and stays out; a flash-red pupil measures 5 and up.
    public static let lowThreshold: Float = 3.2
    public static let highThreshold: Float = 4.8
    /// Blue over green (each lifted by a fiftieth of the red) where the
    /// "flash red, not brown" factor starts and is full.
    public static let purpleLow: Float = 0.35
    public static let purpleHigh: Float = 0.6

    /// The redness measure: red over the larger of green and blue, with a
    /// floor so near-black noise doesn't count. The default floor is for
    /// display-referred values such as a rendered image's; the kernel,
    /// on camera values a stop or two lower, uses a fifth of it.
    public static func redness(_ c: SIMD3<Float>, floor: Float = 0.005) -> Float {
        c.x / max(max(c.y, c.z), floor)
    }

    /// Whether a colour (linear Display P3, display-referred) counts as
    /// pupil red: red enough for the mask to start, and at least halfway
    /// from brown to magenta-red.
    public static func isPupilRed(_ c: SIMD3<Float>) -> Bool {
        let lift = 0.02 * max(c.x, 0)
        let purple = (max(c.z, 0) + lift) / max(max(c.y, 0) + lift, 1e-6)
        return redness(c) >= lowThreshold && purple >= (purpleLow + purpleHigh) / 2
    }

    /// Camera RGB -> linear Display P3, given the camera -> working matrix.
    static func cameraToP3(_ cameraToWorking: simd_float3x3) -> simd_float3x3 {
        ColorKit.displayP3ToXYZ.inverse * ColorKit.rec2020ToXYZ * cameraToWorking
    }
}

/// Mirror of `RedEyeSpotGPU` in RedEye.metal.
struct RedEyeSpotGPU {
    var centre: SIMD2<Float>      // texture pixels
    var radius: Float             // texture pixels
    var strength: Float
    var boxOrigin: SIMD2<Int32>
    var boxSize: SIMD2<Int32>
    var catchlight: SIMD2<Float> = .zero  // unit direction; zero for none
    var pet: Float = 0                    // 1 for Pet Eye
    var catchlightOn: Float = 0
}

enum RedEyeStage {
    /// The spot's placement on a `width` x `height` texture, or nil when
    /// it misses the texture or does nothing.
    static func place(_ spot: RedEyeSpot, width: Int, height: Int, sensorSize: SIMD2<Float>,
                      tileOrigin: SIMD2<Float>, binSpan: Float) -> RedEyeSpotGPU? {
        guard !spot.isIdentity else { return nil }
        let radius = spot.radius * min(sensorSize.x, sensorSize.y) / binSpan
        let centre = (spot.centre * sensorSize - tileOrigin) / binSpan
        // Only the circle is written; the smoothing reads past it, but
        // samples the whole texture for that.
        let reach = radius + 2
        let lo = (centre - reach).rounded(.down), hi = (centre + reach).rounded(.up)
        guard case let (x0, y0, x1, y1)? = HealStage.box(lo, hi, width, height), radius > 0 else { return nil }
        // Binning is the same on both axes, so the catchlight's direction
        // in sensor pixels is its direction in texture pixels.
        let glint = spot.catchlightDirection
        return RedEyeSpotGPU(centre: centre, radius: radius, strength: min(max(spot.strength, 0), 1),
                             boxOrigin: SIMD2(Int32(x0), Int32(y0)), boxSize: SIMD2(Int32(x1 - x0), Int32(y1 - y0)),
                             catchlight: glint ?? .zero, pet: spot.isPet ? 1 : 0, catchlightOn: glint == nil ? 0 : 1)
    }

    /// Corrects `spots`, in order, in `state` (the heal stage's working
    /// texture, already holding the image), each over its own box through
    /// `scratch` so no pixel reads a neighbour already corrected.
    static func encode(_ spots: [RedEyeSpotGPU], state: MTLTexture, scratch: MTLTexture,
                       cameraToWorking: simd_float3x3, encoder: MTLComputeCommandEncoder, gpu: GPUContext) {
        var toP3 = RedEyeTuning.cameraToP3(cameraToWorking)
        var fromP3 = toP3.inverse
        for var spot in spots {
            let box = (Int(spot.boxSize.x), Int(spot.boxSize.y))
            encoder.setComputePipelineState(gpu.redEyeApplyPSO)
            encoder.setTexture(state, index: 0)
            encoder.setTexture(scratch, index: 1)
            encoder.setBytes(&spot, length: MemoryLayout<RedEyeSpotGPU>.stride, index: 0)
            encoder.setBytes(&toP3, length: MemoryLayout<simd_float3x3>.stride, index: 1)
            encoder.setBytes(&fromP3, length: MemoryLayout<simd_float3x3>.stride, index: 2)
            dispatch(encoder, gpu.redEyeApplyPSO, box)

            encoder.setComputePipelineState(gpu.redEyePastePSO)
            encoder.setTexture(scratch, index: 0)
            encoder.setTexture(state, index: 1)
            encoder.setBytes(&spot, length: MemoryLayout<RedEyeSpotGPU>.stride, index: 0)
            dispatch(encoder, gpu.redEyePastePSO, box)
        }
    }

    private static func dispatch(_ encoder: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState,
                                 _ size: (Int, Int)) {
        let tw = pso.threadExecutionWidth
        let th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        encoder.dispatchThreadgroups(MTLSize(width: (size.0 + tw - 1) / tw, height: (size.1 + th - 1) / th, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }
}

/// Hashable over every stored property, for the heal cache's key.
extension RedEyeSpot: Hashable {}
