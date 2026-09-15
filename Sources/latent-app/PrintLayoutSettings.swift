import AppKit
import PixelEngine

/// The print layout set in the print panel's Latent section: how many
/// pictures a sheet of paper holds, how they sit on it, and the colour they
/// are rendered in. Ported from minivu's print settings.
struct PrintLayoutSettings: Codable, Equatable, Sendable {
    /// What the pictures are rendered in before the printing system matches
    /// them to the printer.
    enum ColorChoice: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Display P3 at 16 bits: wider than sRGB, covering most of what
        /// photo printers reach.
        case displayP3
        /// Converted into the printer or paper profile chosen for Soft
        /// Proof, so the print matches the proof.
        case proofProfile

        var id: String { rawValue }
    }

    /// One of `PageLayout.imagesPerPageChoices`.
    var imagesPerPage = 1
    var scaling: LayoutScaling = .fit
    /// Around the paper's edge, in points; never less than the printer's
    /// own unprintable edge.
    var margin = 18.0
    /// Between pictures, in points.
    var spacing = 12.0
    var caption: CaptionContent = .none
    var autoRotate = true
    var color: ColorChoice = .proofProfile

    static let marginRange = 0.0...72.0
    static let spacingRange = 0.0...36.0
    /// Captions print at the size of small body text.
    static let captionFontSize = 9.0

    init() {}

    /// Fields missing from an older store keep their defaults; values out
    /// of range are brought back.
    init(from decoder: any Decoder) throws {
        let defaults = PrintLayoutSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        imagesPerPage = (try? c.decode(Int.self, forKey: .imagesPerPage)) ?? defaults.imagesPerPage
        scaling = (try? c.decode(LayoutScaling.self, forKey: .scaling)) ?? defaults.scaling
        margin = (try? c.decode(Double.self, forKey: .margin)) ?? defaults.margin
        spacing = (try? c.decode(Double.self, forKey: .spacing)) ?? defaults.spacing
        caption = (try? c.decode(CaptionContent.self, forKey: .caption)) ?? defaults.caption
        autoRotate = (try? c.decode(Bool.self, forKey: .autoRotate)) ?? defaults.autoRotate
        color = (try? c.decode(ColorChoice.self, forKey: .color)) ?? defaults.color
        self = validated
    }

    var validated: PrintLayoutSettings {
        var copy = self
        if !PageLayout.imagesPerPageChoices.contains(copy.imagesPerPage) { copy.imagesPerPage = 1 }
        copy.margin = min(max(copy.margin, Self.marginRange.lowerBound), Self.marginRange.upperBound)
        copy.spacing = min(max(copy.spacing, Self.spacingRange.lowerBound), Self.spacingRange.upperBound)
        return copy
    }

    var style: PageStyle {
        PageStyle(background: nil, caption: caption, captionFontSize: Self.captionFontSize)
    }

    /// The profile pictures are converted into: the proof profile when
    /// that is the choice and one is set, else none (Display P3).
    func profile(proof: SheetProfile?) -> SheetProfile? {
        color == .proofProfile ? proof : nil
    }
}

/// Remembers the print layout between prints and launches.
struct PrintLayoutStore {
    let defaults: UserDefaults
    static let key = "latent.printLayout"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settings: PrintLayoutSettings {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let settings = try? JSONDecoder().decode(PrintLayoutSettings.self, from: data)
            else { return PrintLayoutSettings() }
            return settings
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue.validated) { defaults.set(data, forKey: Self.key) }
        }
    }
}

/// The sheet of paper a print goes on, as the print panel has it set.
struct PrintPaper: Sendable, Equatable {
    /// In points, with the orientation applied.
    var size: CGSize
    /// The part of the paper the printer can mark, in paper coordinates
    /// with y growing upwards (AppKit's `imageablePageBounds`).
    var imageableBounds: CGRect
    /// Page Setup's scale; 1 is 100%.
    var scale: Double
    /// The printer's output resolution in dots per inch.
    var dotsPerInch: Double

    init(size: CGSize, imageableBounds: CGRect? = nil, scale: Double = 1, dotsPerInch: Double = 300) {
        self.size = size
        self.imageableBounds = imageableBounds ?? CGRect(origin: .zero, size: size)
        // Page Setup goes down to 1%; below 10% nothing on the page is
        // legible, and a layout ten times the sheet is plenty to render for.
        self.scale = scale > 0 ? max(scale, 0.1) : 1
        self.dotsPerInch = dotsPerInch > 0 ? dotsPerInch : 300
    }

    init(printInfo: NSPrintInfo) {
        let size = printInfo.paperSize
        self.init(size: size.width > 0 && size.height > 0 ? size : CGSize(width: 595, height: 842),
                  imageableBounds: printInfo.imageablePageBounds,
                  scale: Double(printInfo.scalingFactor),
                  dotsPerInch: Self.resolution(of: printInfo) ?? 300)
    }

    /// The page in the print view's units: the paper at Page Setup's scale,
    /// so a 50% scale lays out a page twice as large that prints half size.
    var pageSize: CGSize { CGSize(width: size.width / scale, height: size.height / scale) }

    /// The part of the sheet the printer can mark, in points from the
    /// sheet's top-left corner with y growing downwards; the whole sheet
    /// when the printer reports nothing sensible.
    var printableSheetRect: CGRect {
        let sheet = CGRect(origin: .zero, size: size)
        let bounds = imageableBounds.intersection(sheet)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return sheet }
        return CGRect(x: bounds.minX, y: size.height - bounds.maxY, width: bounds.width, height: bounds.height)
    }

    /// The printer's unprintable edge on each side, in the view's units.
    var unprintableInsets: LayoutInsets {
        let bounds = imageableBounds.intersection(CGRect(origin: .zero, size: size))
        guard !bounds.isNull else { return .zero }
        return LayoutInsets(top: max(0, size.height - bounds.maxY) / scale, left: max(0, bounds.minX) / scale,
                            bottom: max(0, bounds.minY) / scale, right: max(0, size.width - bounds.maxX) / scale)
    }

    /// Render pixels per view unit for the printer. Capped at 360 dpi, the
    /// native resolution of photo inkjets' drivers: past it a photo gains
    /// nothing visible and a 16-bit render of a full sheet costs hundreds of
    /// megabytes. Below 150 dpi a printer is misreporting.
    var pixelsPerUnit: Double { min(max(dotsPerInch, 150), 360) / 72 * scale }

    func layout(for settings: PrintLayoutSettings, imageCount: Int) -> PageLayout {
        let settings = settings.validated
        let page = pageSize
        let hardware = unprintableInsets
        let margins = LayoutInsets(top: max(settings.margin, hardware.top), left: max(settings.margin, hardware.left),
                                   bottom: max(settings.margin, hardware.bottom), right: max(settings.margin, hardware.right))
        var layout = PageLayout(pageSize: page, margins: margins, spacing: settings.spacing,
                                captionHeight: settings.caption.height(fontSize: PrintLayoutSettings.captionFontSize),
                                scaling: settings.scaling, autoRotate: settings.autoRotate, centersPartialPages: true)
        let grid = PageLayout.grid(imagesPerPage: settings.imagesPerPage, pageSize: layout.contentRect.size)
        layout.columns = grid.columns
        layout.rows = grid.rows
        return layout
    }

    /// The resolution the print settings ask for, or failing that the
    /// printer's highest; nil when there is no printer.
    static func resolution(of printInfo: NSPrintInfo) -> Double? {
        let session = OpaquePointer(printInfo.pmPrintSession())
        let settings = OpaquePointer(printInfo.pmPrintSettings())
        var printer: PMPrinter?
        guard PMSessionGetCurrentPrinter(session, &printer) == noErr, let printer else { return nil }
        var resolution = PMResolution()
        if PMPrinterGetOutputResolution(printer, settings, &resolution) == noErr, resolution.hRes > 0 {
            return max(resolution.hRes, resolution.vRes)
        }
        var count: UInt32 = 0
        guard PMPrinterGetPrinterResolutionCount(printer, &count) == noErr, count > 0 else { return nil }
        var best = 0.0
        for index in 1...count where PMPrinterGetIndexedPrinterResolution(printer, index, &resolution) == noErr {
            best = max(best, resolution.hRes, resolution.vRes)
        }
        return best > 0 ? best : nil
    }
}

/// How large pictures are rendered for printing.
enum PrintRenderPolicy {
    /// A photo filling a large sheet at 360 dpi needs about this many
    /// pixels; more only costs memory.
    static let maxLongEdge = 6000
    /// Room for a couple of sheet-sized 16-bit renders.
    static let cacheBudget = 384 << 20
}

/// Lengths as people measure paper: millimetres, or inches where the
/// locale uses them.
enum PrintLength {
    static func text(points: Double, locale: Locale = .current) -> String {
        if locale.measurementSystem == .us {
            return (points / 72).formatted(.number.precision(.fractionLength(0...2)).locale(locale)) + " in"
        }
        return (points / 72 * 25.4).formatted(.number.precision(.fractionLength(0...1)).locale(locale)) + " mm"
    }
}
