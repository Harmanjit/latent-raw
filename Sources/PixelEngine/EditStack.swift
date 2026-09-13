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
    /// the user upgrades them, must keep rendering as they did.
    public static let processVersion = "1.0"

    public var schema: Int = EditStack.schemaVersion
    public var process: String = EditStack.processVersion
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
    }

    public struct Presence: Codable, Equatable, Sendable {
        public var texture: Float, clarity: Float, dehaze: Float
    }
    public struct Vibrance: Codable, Equatable, Sendable { public var amount: Float }
    public struct Defringe: Codable, Equatable, Sendable { public var purple: Float, green: Float }
    public struct Perspective: Codable, Equatable, Sendable { public var vertical: Float, horizontal: Float }

    /// Normalized sensor coordinates; see `CropParameters`.
    public struct Crop: Codable, Equatable, Sendable {
        public var cx: Float, cy: Float, w: Float, h: Float
        public var angle: Float
        public var aspect: Float?
    }

    public struct Curve: Codable, Equatable, Sendable {
        /// [[x, y], ...]
        public var points: [[Float]]
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
        }
    }

    public struct Denoise: Codable, Equatable, Sendable {
        public var luminance: Float
        public var color: Float
    }
    public struct Sharpen: Codable, Equatable, Sendable {
        public var amount: Float
        public var radius: Float
        public var threshold: Float
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
        modules.curve = Curve(points: p.toneCurve.points.map { [$0.x, $0.y] })
        modules.hsl = p.hsl
        modules.splittoning = p.splitToning
        modules.locals = p.locals.isEmpty ? nil : p.locals
        modules.heal = p.heals.isEmpty ? nil : p.heals
        modules.presence = (p.texture == 0 && p.clarity == 0 && p.dehaze == 0) ? nil
            : Presence(texture: p.texture, clarity: p.clarity, dehaze: p.dehaze)
        modules.vibrance = p.vibrance == 0 ? nil : Vibrance(amount: p.vibrance)
        modules.defringe = (p.defringePurple == 0 && p.defringeGreen == 0) ? nil
            : Defringe(purple: p.defringePurple, green: p.defringeGreen)
        modules.perspective = p.perspective.isIdentity ? nil
            : Perspective(vertical: p.perspective.vertical, horizontal: p.perspective.horizontal)
        modules.crop = (p.crop.isIdentity && p.crop.aspect == nil) ? nil
            : Crop(cx: p.crop.centre.x, cy: p.crop.centre.y, w: p.crop.size.x, h: p.crop.size.y,
                   angle: p.crop.angle, aspect: p.crop.aspect)
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
        }
        if let h = modules.hsl, h.hue.count == 8, h.saturation.count == 8, h.luminance.count == 8 {
            p.hsl = h
        }
        if let st = modules.splittoning { p.splitToning = st }
        p.locals = modules.locals ?? []
        p.heals = modules.heal ?? []
        if let pr = modules.presence { p.texture = pr.texture; p.clarity = pr.clarity; p.dehaze = pr.dehaze }
        else { p.texture = 0; p.clarity = 0; p.dehaze = 0 }
        p.vibrance = modules.vibrance?.amount ?? 0
        if let d = modules.defringe { p.defringePurple = d.purple; p.defringeGreen = d.green }
        else { p.defringePurple = 0; p.defringeGreen = 0 }
        if let ps = modules.perspective {
            p.perspective = PerspectiveCorrection(vertical: ps.vertical, horizontal: ps.horizontal)
        } else {
            p.perspective = .none
        }
        if let c = modules.crop, c.w > 0, c.h > 0 {
            p.crop = CropParameters(centre: [c.cx, c.cy], size: [c.w, c.h], angle: c.angle, aspect: c.aspect)
        } else {
            p.crop = .none
        }
        return p
    }

    // MARK: - JSON

    public func encodeJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    public static func decode(json: String) throws -> EditStack {
        try JSONDecoder().decode(EditStack.self, from: Data(json.utf8))
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
