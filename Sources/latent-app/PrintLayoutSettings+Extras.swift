import AppKit
import ColorKit
import PixelEngine

/// The units the print panel shows margins in. Stored in points whatever
/// the unit, so changing it never moves a margin.
enum PrintMarginUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case points, millimetres, inches

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .points: "pt"
        case .millimetres: "mm"
        case .inches: "in"
        }
    }

    /// Points in one unit.
    var points: Double {
        switch self {
        case .points: 1
        case .millimetres: 72 / 25.4
        case .inches: 72
        }
    }

    /// The unit `PrintLength` uses for the locale.
    static func automatic(locale: Locale = .current) -> PrintMarginUnit {
        locale.measurementSystem == .us ? .inches : .millimetres
    }

    func text(points value: Double, locale: Locale = .current) -> String {
        let digits = self == .points ? 0...0 : self == .inches ? 0...2 : 0...1
        return (value / points).formatted(.number.precision(.fractionLength(digits)).locale(locale)) + " " + symbol
    }
}

extension PrintLayoutSettings {
    /// The margin on each side the settings ask for, before the printer's
    /// own unprintable edge is taken into account.
    var margins: LayoutInsets { customMargins ?? LayoutInsets(all: margin) }

    /// Whether the four margins are locked together (one slider).
    var marginsLocked: Bool { customMargins == nil }

    /// A margin length as the panel shows it, in the chosen unit.
    func marginText(_ points: Double) -> String {
        marginUnit.map { $0.text(points: points) } ?? PrintLength.text(points: points)
    }

    /// The print's own profile, with the print's intent, when `.icc` is
    /// chosen and its file can be opened; nil otherwise (Display P3).
    func printProfile() -> SheetProfile? {
        guard let data = printProfileBookmark, let url = PrintProfileBookmarks.resolve(data),
              var profile = SheetProfile(url: url) else { return nil }
        profile.intent = intent
        return profile
    }

    /// The profile pictures would print into, for the panel's summary.
    func colourDescription(proofProfileName: String?) -> String {
        switch color {
        case .icc:
            printProfileName.map { "Printer profile: \($0)" } ?? "Display P3 (wide gamut)"
        case .proofProfile, .displayP3:
            PrintAccessoryController.colorTitle(color == .proofProfile && proofProfileName != nil ? .proofProfile : .displayP3,
                                                proofProfileName: proofProfileName)
        }
    }

    /// Whether the rendering intent applies: pictures are going into a profile.
    func usesIntent(proofProfileName: String?) -> Bool {
        (color == .proofProfile && proofProfileName != nil) || (color == .icc && printProfileBookmark != nil)
    }
}

/// The print profile's bookmark resolved once per launch, with its
/// security scope opened (and left open, as Soft Proof's added profiles
/// are: a print may be using the file).
enum PrintProfileBookmarks {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var resolved: [Data: URL] = [:]

    static func resolve(_ data: Data) -> URL? {
        if let url = lock.withLock({ resolved[data] }) { return url }
        guard let (url, _) = BookmarkStore.resolveQuietly(data) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        lock.withLock { resolved[data] = url }
        return url
    }

    /// A bookmark for a profile the user chose (in an open panel, or from
    /// Soft Proof's list), or nil for a file that isn't a usable profile.
    static func bookmark(for url: URL) -> Data? {
        guard ICCProfile(url: url) != nil, let data = BookmarkStore.bookmark(for: url) else { return nil }
        lock.withLock { resolved[data] = url }
        return data
    }
}

/// What a print's pictures are rendered with beyond the layout: the profile
/// they go into, a preset for the print alone, and output sharpening at the
/// printer's resolution. Renders made with one set mustn't print for another.
struct PrintRenderOptions: Sendable {
    var profile: SheetProfile?
    var presetStyle: PresetStyle?
    var sharpening: OutputSharpening?
    /// The resolution sharpening is worked out for.
    var ppi: Double

    init(settings: PrintLayoutSettings, proofProfile: SheetProfile?, paper: PrintPaper) {
        profile = settings.profile(proof: proofProfile)
        presetStyle = settings.presetStyle
        sharpening = settings.sharpening
        ppi = min(max(paper.dotsPerInch, 150), 360)
    }

    func rendersLike(_ other: PrintRenderOptions) -> Bool {
        let sameProfile = profile == nil ? other.profile == nil : profile!.rendersLike(other.profile)
        return sameProfile && presetStyle == other.presetStyle && sharpening == other.sharpening
            && (sharpening == nil || ppi == other.ppi)
    }
}
