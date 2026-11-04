import Foundation
import ColorKit

/// The persisted form of an edit (DESIGN.md §5.6).
///
/// Organised by module so that adding a module later — lens corrections,
/// grading, masks — is purely additive: an old sidecar simply lacks the
/// key and the module takes its default. Fields are optional for the same
/// reason in the other direction: a newer sidecar with a module this build
/// doesn't know is read without complaint and the unknown part ignored.
///
/// What's deliberately *not* here: the output colour space (an export
/// choice), rotation (catalog metadata, stored beside rating), and
/// anything about the display. The edit stack describes the photograph,
/// not the destination.
public struct EditStack: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    /// Bumped when an algorithm changes in a way that would render old
    /// edits differently. Existing sidecars keep their version and, until
    /// the user upgrades them, must keep rendering as they did
    /// (`ProcessVersion`).
    public static let processVersion = ProcessVersion.current.id

    public var schema: Int = EditStack.schemaVersion
    public var process: String = EditStack.processVersion
    /// Which grid the normalized geometry (crop, local masks, heals,
    /// red-eye, dust, faces and blemishes) measures:
    /// `EditStack.activeAreaFrame`, the camera's active area, for anything
    /// written since the sensor plane was cut to it.
    /// Absent from older stacks, whose (0, 0)...(1, 1) spanned the whole
    /// sensor readout, masked border included; `migratingGeometry(to:)`
    /// moves those onto the active area. Only written when there is
    /// geometry, so a stack without any encodes exactly as before.
    public var frame: String?
    public var modules: Modules = Modules()

    public struct Modules: Codable, Equatable, Sendable {
        public var whitebalance: WhiteBalance?
        public var exposure: Exposure?
        public var tone: Tone?
        public var highlights: Highlights?
        public var demosaic: Demosaic?
        public var denoise: Denoise?
        public var sharpen: Sharpen?
        public var lens: Lens?
        public var curve: Curve?
        public var hsl: HSLAdjustments?
        public var splittoning: SplitToning?
        public var locals: [LocalAdjustment]?
        public var crop: Crop?
        public var heal: [HealPatch]?
        public var presence: Presence?
        public var vibrance: Vibrance?
        public var defringe: Defringe?
        public var perspective: Perspective?
        public var aidenoise: AIDenoise?
        /// Highlights, Shadows, Whites, Blacks. Absent when all are zero,
        /// so edits that never touched them encode exactly as before.
        public var toneranges: ToneRanges?
        /// Red-eye corrections. Absent when there are none.
        public var redeye: [RedEyeSpot]?
        /// Automatic sensor-dust patches (docs/Retouch.md §6). Absent
        /// when there are none, so the 0.9.0 beta reads the rest.
        public var dust: [HealPatch]?
        /// Touch-up (docs/Retouch.md §7). Absent when neutral.
        public var touchup: TouchUp?
        /// Global saturation, Black & White, Colour Grading's additions to
        /// split toning, Calibration and Point Colour (ColourControls.swift).
        /// Each absent while neutral, so older edits encode as before.
        public var saturation: Saturation?
        public var blackwhite: BlackAndWhite?
        public var colorgrading: ColourGrading?
        public var calibration: Calibration?
        public var pointcolor: [PointColour]?
        /// The camera or creative profile. Absent for Latent Standard, so
        /// edits that never chose one encode exactly as before.
        public var profile: ProfileChoice?
        /// Post-crop vignetting and grain (DetailEffects.swift). Absent
        /// while off.
        public var vignette: PostCropVignette?
        public var grain: Grain?
        /// Lens Blur (LensBlur.swift). Absent when neutral, so an edit
        /// that never used it encodes exactly as before.
        public var lensblur: LensBlur?
        /// Distraction Removal › Reflections (ReflectionRemoval.swift).
        /// Absent while off, so older edits encode exactly as before.
        public var reflections: ReflectionRemoval?
        /// HDR Limit (`HDRLimit`). Absent at the default two stops, so
        /// edits that never touched it encode exactly as before.
        public var hdr: HDR?
        /// Flat-field correction (FlatField.swift). Absent when there is
        /// none, so edits that never used it encode exactly as before.
        public var flatfield: FlatFieldCorrection?
    }

    public struct HDR: Codable, Equatable, Sendable { public var limit: Float }

    public struct AIDenoise: Codable, Equatable, Sendable {
        public var strength: Float
        /// Which network produced the result the strength refers to.
        public var model: String
    }
    public static let aiDenoiseModelName = "nafnet-sidd-w32"

    public struct Presence: Codable, Equatable, Sendable {
        public var texture: Float, clarity: Float, dehaze: Float
    }
    public struct Vibrance: Codable, Equatable, Sendable { public var amount: Float }
    public struct Defringe: Codable, Equatable, Sendable {
        public var purple: Float, green: Float
        /// The hue ranges, absent while they are the standard ones.
        public var hues: DefringeHueRanges?
    }
    /// Keystone, and since the Transform panel the rest of the geometry
    /// that composes into the same homography. Each newer field is
    /// optional and only written when it differs from its default, so a
    /// stack without them encodes, and renders, exactly as before.
    public struct Perspective: Codable, Equatable, Sendable {
        public var vertical: Float, horizontal: Float
        public var rotate: Float?
        public var aspect: Float?
        public var scale: Float?
        public var offsetX: Float?
        public var offsetY: Float?
        public var flipHorizontal: Bool?
        public var flipVertical: Bool?
        public var upright: UprightCorrection?
        public var constrainCrop: Bool?

        public init(vertical: Float, horizontal: Float) {
            self.vertical = vertical; self.horizontal = horizontal
        }
    }

    /// Normalized sensor coordinates; see `CropParameters`.
    public struct Crop: Codable, Equatable, Sendable {
        public var cx: Float, cy: Float, w: Float, h: Float
        public var angle: Float
        public var aspect: Float?
    }

    public struct Curve: Codable, Equatable, Sendable {
        /// [[x, y], ...]
        public var points: [[Float]]
        /// Channel curves in the same form, each absent while it's a
        /// straight line (and in every stack older than them).
        public var red: [[Float]]?
        public var green: [[Float]]?
        public var blue: [[Float]]?
        /// The region sliders and their splits, absent while neutral (and
        /// in every stack older than them).
        public var parametric: ParametricCurve?
        /// Refine Saturation, absent at 0.
        public var saturation: Float?

        public init(points: [[Float]], red: [[Float]]? = nil, green: [[Float]]? = nil, blue: [[Float]]? = nil,
                    parametric: ParametricCurve? = nil, saturation: Float? = nil) {
            self.points = points; self.red = red; self.green = green; self.blue = blue
            self.parametric = parametric; self.saturation = saturation
        }

        init(master: ToneCurve, channels: RGBCurves, parametric: ParametricCurve = .neutral, saturation: Float = 0) {
            func encoded(_ c: ToneCurve) -> [[Float]] { c.points.map { [$0.x, $0.y] } }
            self.init(points: encoded(master),
                      red: channels.red.isIdentity ? nil : encoded(channels.red),
                      green: channels.green.isIdentity ? nil : encoded(channels.green),
                      blue: channels.blue.isIdentity ? nil : encoded(channels.blue),
                      parametric: parametric.isNeutral ? nil : parametric,
                      saturation: saturation == 0 ? nil : saturation)
        }

        /// A usable curve from stored points, or nil when there are fewer
        /// than two well-formed ones.
        static func decoded(_ points: [[Float]]?) -> ToneCurve? {
            let pts = (points ?? []).compactMap { $0.count == 2 ? SIMD2<Float>($0[0], $0[1]) : nil }
            return pts.count >= 2 ? ToneCurve(points: pts) : nil
        }
    }

    /// DESIGN.md §5.6: which corrections are on, and which profile and
    /// database version supplied them, frozen so a later database update
    /// can't silently change an edited photo.
    public struct Lens: Codable, Equatable, Sendable {
        public var distortion: Bool = true
        public var tca: Bool = true
        public var vignetting: Bool = true
        public var manualDistortion: Float = 0
        public var manualVignetting: Float = 0
        public var profile: String?
        public var lensfunDb: String?
        /// Manual vignetting's Midpoint, absent at its default (0.5).
        public var vignettingMidpoint: Float?
        /// Measured chromatic aberration, absent while Remove Chromatic
        /// Aberration is off.
        public var autoCA: AutoChromaticAberration?
        /// The Lensfun model picked by hand for this photo, absent for the
        /// automatic profile. `profile` records which one was used.
        public var manualProfile: String?

        public init(distortion: Bool, tca: Bool, vignetting: Bool,
                    manualDistortion: Float, manualVignetting: Float,
                    profile: String?, lensfunDb: String?) {
            self.distortion = distortion; self.tca = tca; self.vignetting = vignetting
            self.manualDistortion = manualDistortion; self.manualVignetting = manualVignetting
            self.profile = profile; self.lensfunDb = lensfunDb
        }

        /// Lenient: any missing key keeps its default, so a sidecar from
        /// another build (or another app's idea of a lens block) loads.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            distortion = try c.decodeIfPresent(Bool.self, forKey: .distortion) ?? true
            tca = try c.decodeIfPresent(Bool.self, forKey: .tca) ?? true
            vignetting = try c.decodeIfPresent(Bool.self, forKey: .vignetting) ?? true
            manualDistortion = try c.decodeIfPresent(Float.self, forKey: .manualDistortion) ?? 0
            manualVignetting = try c.decodeIfPresent(Float.self, forKey: .manualVignetting) ?? 0
            profile = try c.decodeIfPresent(String.self, forKey: .profile)
            lensfunDb = try c.decodeIfPresent(String.self, forKey: .lensfunDb)
            vignettingMidpoint = try c.decodeIfPresent(Float.self, forKey: .vignettingMidpoint)
            autoCA = try c.decodeIfPresent(AutoChromaticAberration.self, forKey: .autoCA)
            manualProfile = try c.decodeIfPresent(String.self, forKey: .manualProfile)
        }
    }

    public struct Denoise: Codable, Equatable, Sendable {
        public var luminance: Float
        public var color: Float
        /// Detail, Contrast and Smoothness, absent at their defaults.
        public var detail: NoiseReductionDetail?
    }
    public struct Sharpen: Codable, Equatable, Sendable {
        public var amount: Float
        public var radius: Float
        public var threshold: Float
        /// Detail and Masking, each absent at its default.
        public var detail: Float?
        public var masking: Float?
    }

    public struct WhiteBalance: Codable, Equatable, Sendable {
        /// "asShot" or "custom".
        public var mode: String
        public var temperature: Float?
        public var tint: Float?
    }
    public struct Exposure: Codable, Equatable, Sendable { public var ev: Float }
    public struct Tone: Codable, Equatable, Sendable {
        public var method: String
        public var contrast: Float
        public var grey: Float
    }
    public struct Highlights: Codable, Equatable, Sendable {
        public var strength: Float
        public var threshold: Float
    }
    public struct Demosaic: Codable, Equatable, Sendable { public var method: String }

    // MARK: - To and from EditParameters

    public init(parameters p: EditParameters) {
        modules.whitebalance = p.whiteBalance.isAsShot
            ? WhiteBalance(mode: "asShot", temperature: nil, tint: nil)
            : WhiteBalance(mode: "custom", temperature: p.whiteBalance.temperature,
                           tint: p.whiteBalance.tint)
        modules.exposure = Exposure(ev: p.exposureEV)
        modules.tone = Tone(method: "sigmoid", contrast: p.contrast, grey: p.greyPoint)
        modules.highlights = Highlights(strength: p.highlightRecovery, threshold: p.highlightThreshold)
        modules.demosaic = Demosaic(method: p.demosaic.rawValue)
        modules.denoise = Denoise(luminance: p.denoiseLuminance, color: p.denoiseColor)
        modules.sharpen = Sharpen(amount: p.sharpenAmount, radius: p.sharpenRadius,
                                  threshold: p.sharpenThreshold)
        modules.lens = Lens(distortion: p.lensDistortion, tca: p.lensTCA, vignetting: p.lensVignetting,
                            manualDistortion: p.manualDistortion, manualVignetting: p.manualVignetting,
                            profile: nil, lensfunDb: nil)
        modules.curve = Curve(master: p.toneCurve, channels: p.channelCurves,
                              parametric: p.parametricCurve, saturation: p.curveSaturation)
        modules.toneranges = p.toneRanges.isNeutral ? nil : p.toneRanges
        modules.hsl = p.hsl
        modules.splittoning = p.splitToning
        modules.locals = p.locals.isEmpty ? nil : p.locals
        modules.heal = p.heals.isEmpty ? nil : p.heals
        modules.redeye = p.redEyes.isEmpty ? nil : p.redEyes
        modules.dust = p.dust.isEmpty ? nil : p.dust
        modules.touchup = p.touchUp.isNeutral ? nil : p.touchUp
        setColourControls(p.colour)
        modules.profile = p.profile?.sanitized
        modules.lensblur = p.lensBlur.isNeutral ? nil : p.lensBlur
        modules.reflections = p.reflections.isNeutral ? nil : p.reflections
        modules.presence = (p.texture == 0 && p.clarity == 0 && p.dehaze == 0) ? nil
            : Presence(texture: p.texture, clarity: p.clarity, dehaze: p.dehaze)
        modules.vibrance = p.vibrance == 0 ? nil : Vibrance(amount: p.vibrance)
        modules.hdr = p.hdrLimitStops == HDRLimit.defaultStops ? nil : HDR(limit: p.hdrLimitStops)
        modules.defringe = (p.defringePurple == 0 && p.defringeGreen == 0) ? nil
            : Defringe(purple: p.defringePurple, green: p.defringeGreen)
        modules.aidenoise = p.aiDenoise == 0 ? nil : AIDenoise(strength: p.aiDenoise, model: Self.aiDenoiseModelName)
        modules.perspective = p.perspective.isNeutral ? nil : Perspective(transform: p.perspective)
        modules.crop = (p.crop.isIdentity && p.crop.aspect == nil) ? nil
            : Crop(cx: p.crop.centre.x, cy: p.crop.centre.y, w: p.crop.size.x, h: p.crop.size.y,
                   angle: p.crop.angle, aspect: p.crop.aspect)
        storeDetailEffects(from: p)
        modules.flatfield = p.flatField?.sanitized
        process = p.processVersion
        // Parameters always measure the sensor plane as it is now.
        frame = hasGeometry ? Self.activeAreaFrame : nil
    }

    /// Records which profile produced this edit. Not part of equality
    /// for `isDefault`, which compares parameters only.
    public mutating func setLensProvenance(profile: String?, databaseVersion: String?) {
        modules.lens?.profile = profile
        modules.lens?.lensfunDb = databaseVersion
    }

    public init() {}

    /// Rebuilds parameters, starting from `defaults` for anything the
    /// stack doesn't mention. `defaults` is normally the fresh set for the
    /// image (as-shot white balance and so on).
    public func parameters(defaults: EditParameters = EditParameters()) -> EditParameters {
        var p = defaults
        if let wb = modules.whitebalance {
            if wb.mode == "custom", let t = wb.temperature {
                p.whiteBalance = ColorKit.WhiteBalance(temperature: t, tint: wb.tint ?? 0)
            } else {
                p.whiteBalance = .asShot
            }
        }
        if let e = modules.exposure { p.exposureEV = e.ev }
        if let t = modules.tone { p.contrast = t.contrast; p.greyPoint = t.grey }
        if let h = modules.highlights {
            p.highlightRecovery = h.strength
            p.highlightThreshold = h.threshold
        }
        if let d = modules.demosaic, let method = DemosaicMethod(rawValue: d.method) {
            p.demosaic = method
        }
        if let n = modules.denoise { p.denoiseLuminance = n.luminance; p.denoiseColor = n.color }
        if let s = modules.sharpen {
            p.sharpenAmount = s.amount; p.sharpenRadius = s.radius; p.sharpenThreshold = s.threshold
        }
        if let l = modules.lens {
            p.lensDistortion = l.distortion; p.lensTCA = l.tca; p.lensVignetting = l.vignetting
            p.manualDistortion = l.manualDistortion; p.manualVignetting = l.manualVignetting
        }
        if let c = modules.curve {
            let pts = c.points.compactMap { $0.count == 2 ? SIMD2<Float>($0[0], $0[1]) : nil }
            if pts.count >= 2 { p.toneCurve = ToneCurve(points: pts) }
            p.channelCurves = RGBCurves(red: Curve.decoded(c.red) ?? .identity,
                                        green: Curve.decoded(c.green) ?? .identity,
                                        blue: Curve.decoded(c.blue) ?? .identity)
            p.parametricCurve = c.parametric?.sanitized ?? .neutral
            p.curveSaturation = c.saturation.map { $0.isFinite ? min(max($0, -1), 1) : 0 } ?? 0
        }
        p.toneRanges = modules.toneranges ?? .neutral
        if let h = modules.hsl, h.hue.count == 8, h.saturation.count == 8, h.luminance.count == 8 {
            p.hsl = h
        }
        if let st = modules.splittoning { p.splitToning = st }
        p.locals = modules.locals ?? []
        // Geometry from a file is checked before anything renders it: a
        // hand-edited coordinate could otherwise overflow the render's pixel
        // arithmetic, or a stroke of a million points take minutes.
        p.heals = (modules.heal ?? []).prefix(HealPatch.maximumCount).compactMap(\.sanitized)
        p.redEyes = (modules.redeye ?? []).prefix(RedEyeSpot.maximumCount).compactMap(\.sanitized)
        p.dust = (modules.dust ?? []).prefix(HealPatch.maximumDustCount).compactMap(\.sanitized)
        p.touchUp = (modules.touchup ?? .neutral).sanitized
        p.profile = modules.profile?.sanitized
        p.lensBlur = (modules.lensblur ?? .neutral).sanitized
        p.reflections = (modules.reflections ?? .neutral).sanitized
        if let pr = modules.presence { p.texture = pr.texture; p.clarity = pr.clarity; p.dehaze = pr.dehaze }
        else { p.texture = 0; p.clarity = 0; p.dehaze = 0 }
        p.vibrance = modules.vibrance?.amount ?? 0
        p.colour = colourControls
        p.hdrLimitStops = HDRLimit.clamped(modules.hdr?.limit ?? HDRLimit.defaultStops)
        if let d = modules.defringe { p.defringePurple = d.purple; p.defringeGreen = d.green }
        else { p.defringePurple = 0; p.defringeGreen = 0 }
        p.aiDenoise = modules.aidenoise?.strength ?? 0
        if let ps = modules.perspective {
            p.perspective = ps.correction
        } else {
            p.perspective = .none
        }
        if let c = modules.crop, c.w > 0, c.h > 0 {
            p.crop = CropParameters(centre: [c.cx, c.cy], size: [c.w, c.h], angle: c.angle, aspect: c.aspect)
        } else {
            p.crop = .none
        }
        restoreDetailEffects(into: &p)
        p.flatField = modules.flatfield?.sanitized
        p.processVersion = process
        return p
    }

    // MARK: - JSON

    public func encodeJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// Reads a stored stack. A stack whose `schema` is newer than this
    /// build's is refused rather than read leniently: its unknown modules
    /// and values would be dropped here, and the next save (which rebuilds
    /// the stack from parameters and stamps this build's schema) would
    /// erase them from the catalog, the sidecar and the history for good.
    /// Refusing makes every caller take its "stored edit can't be read"
    /// path, which tells the user instead of quietly losing the edit.
    public static func decode(json: String) throws -> EditStack {
        let stack = try JSONDecoder().decode(EditStack.self, from: Data(json.utf8))
        guard stack.schema <= schemaVersion else {
            throw DecodeError.newerSchema(stack.schema)
        }
        return stack
    }

    public enum DecodeError: Error, LocalizedError, Equatable {
        /// The stack was written by a newer Latent, in this edit format.
        case newerSchema(Int)

        public var errorDescription: String? {
            switch self {
            case .newerSchema(let found):
                return "The edit was made with a newer version of Latent (edit format \(found); "
                    + "this version reads format \(EditStack.schemaVersion)). Open it in the newer version."
            }
        }
    }

    /// True when the stack changes nothing about the default rendering, in
    /// which case there's no point storing it.
    public static func isDefault(_ p: EditParameters, relativeTo defaults: EditParameters) -> Bool {
        var a = EditStack(parameters: p), b = EditStack(parameters: defaults)
        a.setLensProvenance(profile: nil, databaseVersion: nil)
        b.setLensProvenance(profile: nil, databaseVersion: nil)
        return a == b
    }
}
