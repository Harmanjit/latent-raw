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
        EditStack(parameters: p) == EditStack(parameters: defaults)
    }
}
