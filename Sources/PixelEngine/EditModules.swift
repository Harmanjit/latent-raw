import Foundation

/// The user-facing groups of an edit, for copy/paste, presets and
/// snapshots. Each group maps to one or more modules of the edit stack
/// (DESIGN.md §5.6), so choosing "Tone" carries exposure, the curve's
/// inputs and highlight recovery together, the way a person thinks of it.
public enum EditGroup: String, CaseIterable, Codable, Sendable, Identifiable {
    case whiteBalance, tone, presence, toneCurve, colour, splitToning, detail, lens, locals, crop, heal, dust, touchUp

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .whiteBalance: return "White Balance"
        case .tone:         return "Tone (exposure, contrast, highlights & shadows, recovery)"
        case .presence:     return "Presence (texture, clarity, dehaze)"
        case .toneCurve:    return "Tone Curve (master and RGB)"
        case .colour:       return "HSL / Colour / Vibrance"
        case .splitToning:  return "Split Toning"
        case .detail:       return "Detail (sharpening, noise, AI denoise)"
        case .lens:         return "Lens Corrections & Defringe"
        case .locals:       return "Local Adjustments"
        case .crop:         return "Crop, Straighten & Perspective"
        case .heal:         return "Spot Removal & Red-Eye"
        case .dust:         return "Sensor Dust"
        case .touchUp:      return "Touch-up (skin, teeth, eyes, blemishes)"
        }
    }

    /// What copy/paste and presets take by default: the look, not the
    /// masks (drawn for another frame) and not the lens correction
    /// switches (a property of the lens, already right per image).
    public static let lookGroups: Set<EditGroup> = [.whiteBalance, .tone, .presence, .toneCurve, .colour, .splitToning, .detail]
}

extension EditStack {
    /// A new stack: this one, with the chosen groups replaced by `other`'s.
    /// Groups not chosen keep their current values; a group absent from
    /// `other` is cleared to its default when chosen (pasting "no curve"
    /// is a legitimate thing to paste).
    public func merged(with other: EditStack, groups: Set<EditGroup>) -> EditStack {
        var result = self
        for group in groups {
            switch group {
            case .whiteBalance:
                result.modules.whitebalance = other.modules.whitebalance
            case .tone:
                result.modules.exposure = other.modules.exposure
                result.modules.tone = other.modules.tone
                result.modules.highlights = other.modules.highlights
                result.modules.toneranges = other.modules.toneranges
            case .presence:
                result.modules.presence = other.modules.presence
            case .toneCurve:
                result.modules.curve = other.modules.curve
            case .colour:
                result.modules.hsl = other.modules.hsl
                result.modules.vibrance = other.modules.vibrance
            case .splitToning:
                result.modules.splittoning = other.modules.splittoning
            case .detail:
                result.modules.denoise = other.modules.denoise
                result.modules.aidenoise = other.modules.aidenoise
                result.modules.sharpen = other.modules.sharpen
                result.modules.demosaic = other.modules.demosaic
            case .lens:
                result.modules.lens = other.modules.lens
                result.modules.defringe = other.modules.defringe
            case .locals:
                result.modules.locals = other.modules.locals
            case .crop:
                result.modules.crop = other.modules.crop
                result.modules.perspective = other.modules.perspective
            case .heal:
                result.modules.heal = other.modules.heal
                result.modules.redeye = other.modules.redeye
            case .dust:
                result.modules.dust = other.modules.dust
            case .touchUp:
                // The sliders travel; the faces and blemishes are this
                // image's own (found on its picture), so they stay, and a
                // preset or the clipboard (built on an empty stack) carries
                // none. Pasting "no touch-up" still clears the module.
                var t = other.modules.touchup
                t?.faces = modules.touchup?.faces ?? []
                t?.blemishes = modules.touchup?.blemishes ?? []
                result.modules.touchup = t
            }
        }
        // The result's geometry keeps the frame it was written in. When it
        // mixes both sides and they disagree (only possible while an image
        // still holds an edit from before the active-area change and is
        // pasted into without being opened) this stack's frame wins: its
        // own heals and masks then stay right, and at worst the pasted
        // geometry lands off by the camera's masked border.
        // Measured on the result, not on `other`: a touch-up copied
        // without its faces brings no geometry along.
        let chosen = groups.intersection([.locals, .crop, .heal, .dust, .touchUp])
        let keepsOwnGeometry = !geometryGroups.subtracting(chosen).isEmpty
        let takesOtherGeometry = !result.geometryGroups.intersection(chosen).isEmpty
        result.frame = keepsOwnGeometry ? frame : (takesOtherGeometry ? other.frame : nil)
        return result
    }

    /// Only the chosen groups, everything else absent — what a preset or
    /// the clipboard should hold, so applying it can't drag along modules
    /// the user didn't mean to copy.
    public func restricted(to groups: Set<EditGroup>) -> EditStack {
        EditStack().merged(with: self, groups: groups)
    }

    /// Which groups this stack actually carries (non-nil modules).
    public var presentGroups: Set<EditGroup> {
        var g: Set<EditGroup> = []
        let m = modules
        if m.whitebalance != nil { g.insert(.whiteBalance) }
        if m.exposure != nil || m.tone != nil || m.highlights != nil || m.toneranges != nil { g.insert(.tone) }
        if m.presence != nil { g.insert(.presence) }
        if m.curve != nil { g.insert(.toneCurve) }
        if m.hsl != nil || m.vibrance != nil { g.insert(.colour) }
        if m.splittoning != nil { g.insert(.splitToning) }
        if m.denoise != nil || m.sharpen != nil || m.demosaic != nil || m.aidenoise != nil { g.insert(.detail) }
        if m.lens != nil || m.defringe != nil { g.insert(.lens) }
        if m.locals != nil { g.insert(.locals) }
        if m.crop != nil || m.perspective != nil { g.insert(.crop) }
        if m.heal != nil || m.redeye != nil { g.insert(.heal) }
        if m.dust != nil { g.insert(.dust) }
        if m.touchup != nil { g.insert(.touchUp) }
        return g
    }
}

/// A named, reusable partial edit.
public struct Preset: Codable, Equatable, Sendable, Identifiable {
    public var name: String
    public var groups: Set<EditGroup>
    public var stack: EditStack
    public var isBuiltIn: Bool = false

    public var id: String { name }

    public init(name: String, groups: Set<EditGroup>, stack: EditStack, isBuiltIn: Bool = false) {
        self.name = name
        self.groups = groups
        self.stack = stack.restricted(to: groups)
        self.isBuiltIn = isBuiltIn
    }

    private enum CodingKeys: String, CodingKey { case name, groups, stack, isBuiltIn }

    /// `groups` decodes leniently: a group this build doesn't know (a
    /// preset saved by a later one) is dropped rather than losing the
    /// whole preset, since presets are shared by every catalog.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        let raw = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        groups = Set(raw.compactMap(EditGroup.init(rawValue:)))
        stack = try c.decode(EditStack.self, forKey: .stack)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }

    /// A few starting points. Deliberately mild: a preset that a user
    /// can't recognise their photo through is a preset they delete.
    public static var builtIns: [Preset] {
        func make(_ name: String, _ groups: Set<EditGroup>, _ edit: (inout EditParameters) -> Void) -> Preset {
            var p = EditParameters(); edit(&p)
            return Preset(name: name, groups: groups, stack: EditStack(parameters: p), isBuiltIn: true)
        }
        return [
            make("Black & White", [.colour, .splitToning]) { p in
                p.hsl.saturation = Array(repeating: -1, count: 8)
            },
            make("Punchy", [.tone, .toneCurve, .colour]) { p in
                p.contrast = 1.8
                p.toneCurve = ToneCurve(points: [SIMD2(0, 0), SIMD2(0.25, 0.2), SIMD2(0.75, 0.82), SIMD2(1, 1)])
                p.hsl.saturation = Array(repeating: 0.2, count: 8)
            },
            make("Soft Film", [.tone, .toneCurve, .splitToning]) { p in
                p.contrast = 1.3
                p.toneCurve = ToneCurve(points: [SIMD2(0, 0.04), SIMD2(0.5, 0.5), SIMD2(1, 0.97)])
                p.splitToning = SplitToning(shadowHue: 215, shadowSaturation: 0.12,
                                            highlightHue: 45, highlightSaturation: 0.12, balance: 0)
            },
            make("Warm Golden Hour", [.whiteBalance, .splitToning]) { p in
                p.whiteBalance = .init(temperature: 6200, tint: 5)
                p.splitToning = SplitToning(shadowHue: 30, shadowSaturation: 0.08,
                                            highlightHue: 40, highlightSaturation: 0.25, balance: 0.2)
            },
            make("Landscape Detail", [.detail, .colour]) { p in
                p.sharpenAmount = 0.9; p.sharpenRadius = 0.9; p.sharpenThreshold = 0.01
                p.denoiseLuminance = 0.15; p.denoiseColor = 0.4
                p.hsl.saturation[3] = 0.15; p.hsl.saturation[5] = 0.15   // green, blue
            },
        ]
    }
}

/// User presets on disk: one JSON file each, in Application Support, so
/// they're shared by every catalog and survive reinstalling the app.
public enum PresetStore {
    public static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("latent/presets", isDirectory: true)
        adoptLegacyDirectory(base.appendingPathComponent("rawhead/presets", isDirectory: true), into: dir)
        return dir
    }

    /// One-time move of the pre-rename app's folder, if the new one
    /// doesn't exist yet. Failure is harmless: the user just starts fresh.
    static func adoptLegacyDirectory(_ old: URL, into new: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) else { return }
        try? fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: old, to: new)
    }

    public static func load() -> [Preset] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let user = files.filter { $0.pathExtension == "json" }.compactMap { url -> Preset? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(Preset.self, from: data)
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }
        return Preset.builtIns + user
    }

    public static func save(_ preset: Preset) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preset).write(to: fileURL(for: preset.name), options: .atomic)
    }

    public static func delete(named name: String) throws {
        try FileManager.default.removeItem(at: fileURL(for: name))
    }

    static func fileURL(for name: String) -> URL {
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return directory.appendingPathComponent(safe + ".json")
    }
}
