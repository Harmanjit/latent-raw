import Foundation
import simd

/// One face the touch-up module works on: where it is, and whether it
/// is switched on.
///
/// The box is on the *raw* sensor grid (normalised active-area
/// coordinates, before lens correction), so lens and keystone edits never
/// invalidate a stored face: regeneration maps it forward through
/// `RenderPipeline.outputSensorPoint` to seed the landmark pass again.
public struct TouchUpFace: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Normalised active-area sensor coordinates on the RAW grid: x, y, w, h.
    public var boundingBox: SIMD4<Float>
    public var enabled: Bool

    public init(id: UUID = UUID(), boundingBox: SIMD4<Float>, enabled: Bool = true) {
        self.id = id
        self.boundingBox = boundingBox
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey { case id, boundingBox, enabled }

    /// Lenient, like a red-eye spot: a face missing a key (another
    /// build's, or a hand-edited sidecar) loads with that key's default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        boundingBox = try c.decodeIfPresent(SIMD4<Float>.self, forKey: .boundingBox) ?? SIMD4(0, 0, 0, 0)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// The face as a render can trust it: a box within a sensor's width
    /// of the sensor. Nil when a number isn't finite.
    var sanitized: TouchUpFace? {
        guard boundingBox.x.isFinite, boundingBox.y.isFinite, boundingBox.z.isFinite, boundingBox.w.isFinite else {
            return nil
        }
        var face = self
        let lo = HealPatch.coordinateRange.lowerBound, hi = HealPatch.coordinateRange.upperBound
        face.boundingBox = simd_clamp(boundingBox, SIMD4(repeating: lo), SIMD4(repeating: hi))
        return face
    }
}

/// The touch-up module (docs/Retouch.md §7): skin smoothing, teeth
/// whitening and brighter eyes per face, and the automatic blemish
/// patches, which stage 5 heals like the user's own.
///
/// Stored in the sidecar only when it isn't neutral, so untouched edits
/// encode exactly as before. Every key is optional on the way in and the
/// numbers are clamped (`sanitized`) before anything renders them.
public struct TouchUp: Codable, Equatable, Sendable {
    /// At most `maximumFaces`, left to right.
    public var faces: [TouchUpFace] = []
    /// 0…100.
    public var skinSmoothing: Float = 0
    public var teethWhitening: Float = 0
    public var eyes: Float = 0
    public var blemishRemoval: Bool = false
    /// At most `HealPatch.maximumBlemishCount`, on the raw grid.
    public var blemishes: [HealPatch] = []
    /// Which landmark pass found the faces (`FaceLandmarker.modelVersion`
    /// in MLKit); empty until faces were found.
    public var modelVersion: String = ""

    public static let neutral = TouchUp()
    public static let maximumFaces = 16

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case faces, skinSmoothing, teethWhitening, eyes, blemishRemoval, blemishes, modelVersion
    }

    /// Every key optional: a module written by a later build, or one a
    /// hand missed a key of, loads with the defaults for what's missing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        faces = try c.decodeIfPresent([TouchUpFace].self, forKey: .faces) ?? []
        skinSmoothing = try c.decodeIfPresent(Float.self, forKey: .skinSmoothing) ?? 0
        teethWhitening = try c.decodeIfPresent(Float.self, forKey: .teethWhitening) ?? 0
        eyes = try c.decodeIfPresent(Float.self, forKey: .eyes) ?? 0
        blemishRemoval = try c.decodeIfPresent(Bool.self, forKey: .blemishRemoval) ?? false
        blemishes = try c.decodeIfPresent([HealPatch].self, forKey: .blemishes) ?? []
        modelVersion = try c.decodeIfPresent(String.self, forKey: .modelVersion) ?? ""
    }

    /// Nothing stored and nothing to do: what the sidecar omits.
    public var isNeutral: Bool { self == Self.neutral }

    public var enabledFaceIDs: Set<UUID> { Set(faces.filter(\.enabled).map(\.id)) }

    /// An enabled face and a non-zero skin, teeth or eyes slider: the
    /// stage needs the region masks to run at all.
    public var wantsMasks: Bool {
        !enabledFaceIDs.isEmpty && (skinSmoothing > 0 || teethWhitening > 0 || eyes > 0)
    }

    /// The blemish patches stage 5 heals: none while Remove Blemishes is
    /// off, so the list survives a toggle.
    public var activeBlemishes: [HealPatch] { blemishRemoval ? blemishes : [] }

    /// The module as a render can trust it, whatever wrote the sidecar:
    /// sliders in 0…100 (a non-finite one is 0), at most `maximumFaces`
    /// faces with boxes within `HealPatch.coordinateRange`, at most
    /// `HealPatch.maximumBlemishCount` blemishes, each sanitised as a heal
    /// patch. A module the app made comes back unchanged.
    public var sanitized: TouchUp {
        func slider(_ v: Float) -> Float { v.isFinite ? min(max(v, 0), 100) : 0 }
        var t = self
        t.skinSmoothing = slider(skinSmoothing)
        t.teethWhitening = slider(teethWhitening)
        t.eyes = slider(eyes)
        t.faces = faces.prefix(Self.maximumFaces).compactMap(\.sanitized)
        t.blemishes = blemishes.prefix(HealPatch.maximumBlemishCount).compactMap(\.sanitized)
        return t
    }

    /// The median width of the enabled faces in sensor pixels (the box's
    /// width times the sensor's), which sets the smoothing scale; nil
    /// with no enabled face.
    public func medianFaceWidthPixels(sensorSize: SIMD2<Float>) -> Float? {
        let widths = faces.filter(\.enabled).map { $0.boundingBox.z * sensorSize.x }.sorted()
        guard !widths.isEmpty else { return nil }
        let mid = widths.count / 2
        return widths.count % 2 == 1 ? widths[mid] : (widths[mid - 1] + widths[mid]) / 2
    }

    /// The wide blur's sigma: clamp(0.035 × faceWidth, 4, 48) sensor px.
    /// The floor when there is no face (the stage doesn't run then).
    public static func sigmaMid(faceWidth: Float?) -> Float {
        guard let faceWidth, faceWidth.isFinite else { return 4 }
        return min(max(0.035 * faceWidth, 4), 48)
    }

    /// How far the stage reads past a pixel it writes: ceil(3 × sigmaMid)
    /// + 2, at most 146 sensor px. Tiles are inset by this beyond their
    /// usual margin so a tile smooths as the whole frame does.
    public static func blurReachPixels(faceWidth: Float?) -> Int {
        Int((3 * sigmaMid(faceWidth: faceWidth)).rounded(.up)) + 2
    }
}
