import Foundation
import CoreGraphics
import UniformTypeIdentifiers
import ColorKit
import PixelEngine

/// Page sizes a contact sheet is made at, in pixels.
enum ContactSheetPageSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case a4, a3, letter, tabloid, uhd4K, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .a4: "A4 at 300 dpi"
        case .a3: "A3 at 300 dpi"
        case .letter: "US Letter at 300 dpi"
        case .tabloid: "Tabloid at 300 dpi"
        case .uhd4K: "4K Display"
        case .custom: "Custom"
        }
    }

    /// The size in its natural (portrait for paper) orientation; nil for Custom.
    var pixelSize: CGSize? {
        switch self {
        case .a4: CGSize(width: 2480, height: 3508)
        case .a3: CGSize(width: 3508, height: 4961)
        case .letter: CGSize(width: 2550, height: 3300)
        case .tabloid: CGSize(width: 3300, height: 5100)
        case .uhd4K: CGSize(width: 3840, height: 2160)
        case .custom: nil
        }
    }

    /// Pixels per inch, which sets a PDF page's size in points: paper sizes
    /// come out at their paper size; a screen size or a custom one at 72.
    var dotsPerInch: Double {
        switch self {
        case .a4, .a3, .letter, .tabloid: 300
        case .uhd4K, .custom: 72
        }
    }
}

enum ContactSheetOrientation: String, Codable, CaseIterable, Identifiable, Sendable {
    case portrait, landscape
    var id: String { rawValue }
    var title: String { self == .portrait ? "Portrait" : "Landscape" }
}

/// What a contact sheet is saved as: one PDF with as many pages as the
/// grid needs, or one picture holding every photo.
enum ContactSheetFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case pdf, jpeg, png

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .jpeg: "JPEG"
        case .png: "PNG"
        }
    }

    var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .jpeg: "jpg"
        case .png: "png"
        }
    }

    var contentType: UTType {
        switch self {
        case .pdf: .pdf
        case .jpeg: .jpeg
        case .png: .png
        }
    }

    var isImage: Bool { self != .pdf }
}

/// The colour space of the page and of the photos rendered onto it.
enum ContactSheetColorSpace: String, Codable, CaseIterable, Identifiable, Sendable {
    case sRGB, displayP3
    var id: String { rawValue }
    var title: String { self == .sRGB ? "sRGB" : "Display P3" }
    var outputSpace: ColorKit.OutputSpace { self == .sRGB ? .sRGB : .displayP3 }
    var cgColorSpace: CGColorSpace {
        CGColorSpace(name: self == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3)!
    }
}

enum ContactSheetBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    case white, lightGrey, darkGrey, black
    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: "White"
        case .lightGrey: "Light Grey"
        case .darkGrey: "Dark Grey"
        case .black: "Black"
        }
    }

    var color: SheetColor {
        switch self {
        case .white: .white
        case .lightGrey: SheetColor(red: 0.9, green: 0.9, blue: 0.9)
        case .darkGrey: SheetColor(red: 0.2, green: 0.2, blue: 0.2)
        case .black: .black
        }
    }
}

/// Everything the Contact Sheet dialog sets. Lengths are in pixels of the
/// page. Remembered between sheets, except the title text, which starts as
/// the folder's name each time.
struct ContactSheetSettings: Codable, Equatable, Sendable {
    var format: ContactSheetFormat = .pdf
    var colorSpace: ContactSheetColorSpace = .sRGB
    var pageSize: ContactSheetPageSize = .a4
    var customWidth = 3000
    var customHeight = 2000
    var orientation: ContactSheetOrientation = .portrait
    var background: ContactSheetBackground = .white
    var columns = 4
    /// 0 is "auto": every photo on one page. A picture (JPEG, PNG) is
    /// always one page, whatever this says.
    var rows = 5
    var spacing = 40
    var margin = 120
    var scaling: LayoutScaling = .fit
    var caption: CaptionContent = .name
    /// Caption text height in pixels; the title is set larger.
    var captionSize = 36
    var showsTitle = true
    var showsPageNumbers = true

    static let columnRange = 1...12
    static let rowRange = 0...20
    static let customSideRange = 512...8192
    static let spacingRange = 0...400
    static let marginRange = 0...800
    static let captionSizeRange = 8...200

    init() {}

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = ContactSheetSettings()
        func read<T: Decodable>(_ key: CodingKeys, _ value: inout T) {
            if let decoded = try? c.decode(T.self, forKey: key) { value = decoded }
        }
        read(.format, &s.format)
        read(.colorSpace, &s.colorSpace)
        read(.pageSize, &s.pageSize)
        read(.customWidth, &s.customWidth)
        read(.customHeight, &s.customHeight)
        read(.orientation, &s.orientation)
        read(.background, &s.background)
        read(.columns, &s.columns)
        read(.rows, &s.rows)
        read(.spacing, &s.spacing)
        read(.margin, &s.margin)
        read(.scaling, &s.scaling)
        read(.caption, &s.caption)
        read(.captionSize, &s.captionSize)
        read(.showsTitle, &s.showsTitle)
        read(.showsPageNumbers, &s.showsPageNumbers)
        self = s.validated
    }

    /// Every number within its range, so a page can always be drawn.
    var validated: ContactSheetSettings {
        func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int { min(max(value, range.lowerBound), range.upperBound) }
        var s = self
        s.customWidth = clamp(s.customWidth, Self.customSideRange)
        s.customHeight = clamp(s.customHeight, Self.customSideRange)
        s.columns = clamp(s.columns, Self.columnRange)
        s.rows = clamp(s.rows, Self.rowRange)
        s.spacing = clamp(s.spacing, Self.spacingRange)
        s.margin = clamp(s.margin, Self.marginRange)
        s.captionSize = clamp(s.captionSize, Self.captionSizeRange)
        return s
    }

    /// The page in pixels: a preset turned to the orientation chosen, a
    /// custom size exactly as typed (its width and height already say which
    /// way up it is, so the dialog hides Orientation for it).
    var pagePixelSize: CGSize {
        guard let natural = pageSize.pixelSize else {
            let s = validated
            return CGSize(width: s.customWidth, height: s.customHeight)
        }
        let long = max(natural.width, natural.height), short = min(natural.width, natural.height)
        return orientation == .portrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short)
    }

    /// Points per page pixel in a PDF: from the preset's resolution, and
    /// never so many that a side passes 14,400 points (200 inches), the
    /// largest page PDF readers such as Acrobat open.
    var pdfPointsPerPixel: Double {
        let longSide = Double(max(pagePixelSize.width, pagePixelSize.height))
        return min(72 / pageSize.dotsPerInch, 14_400 / max(longSide, 1))
    }

    var titleFontSize: Double { Double(captionSize) * 1.6 }

    /// Rows as the output takes them: nil (auto, one page) for a picture.
    var effectiveRows: Int? {
        let s = validated
        return s.format.isImage || s.rows == 0 ? nil : s.rows
    }

    func layout(imageCount: Int, title: String?) -> PageLayout {
        let s = validated
        let hasTitle = s.showsTitle && !(title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        let numbered = s.showsPageNumbers && s.format == .pdf
        return PageLayout(pageSize: s.pagePixelSize, margins: LayoutInsets(all: Double(s.margin)),
                          columns: s.columns, rows: effectiveRows, spacing: Double(s.spacing),
                          captionHeight: s.caption.height(fontSize: Double(s.captionSize)),
                          headerHeight: hasTitle ? s.titleFontSize * 2 : 0,
                          footerHeight: numbered ? Double(s.captionSize) * 2.2 : 0,
                          scaling: s.scaling, autoRotate: false, centersPartialPages: false)
    }

    func style(title: String?) -> PageStyle {
        let s = validated
        let trimmed = title?.trimmingCharacters(in: .whitespaces) ?? ""
        return PageStyle(background: s.background.color, caption: s.caption, captionFontSize: Double(s.captionSize),
                         header: s.showsTitle && !trimmed.isEmpty ? trimmed : nil, headerFontSize: s.titleFontSize,
                         showsPageNumbers: s.showsPageNumbers && s.format == .pdf)
    }

    func pageCount(imageCount: Int) -> Int {
        layout(imageCount: imageCount, title: nil).pageCount(forImageCount: imageCount)
    }

    /// The largest render a cell asks for: a page with a single cell
    /// doesn't need a photo larger than the page.
    static let maxRenderLongEdge = 4096
}

/// Remembers the contact sheet settings between sheets and launches.
struct ContactSheetStore {
    let defaults: UserDefaults
    static let key = "latent.contactSheet"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var settings: ContactSheetSettings {
        get {
            guard let data = defaults.data(forKey: Self.key),
                  let settings = try? JSONDecoder().decode(ContactSheetSettings.self, from: data)
            else { return ContactSheetSettings() }
            return settings
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue.validated) { defaults.set(data, forKey: Self.key) }
        }
    }
}

enum ContactSheetNaming {
    /// "Trip Contact Sheet.pdf" from the title (the folder's name to begin
    /// with). The title is free text, so it is made a safe file name: a "/"
    /// or ":" would name a folder that isn't there, a leading dot would hide
    /// the file, and a very long title would pass the 255 bytes a name has.
    static func fileName(title: String?, format: ContactSheetFormat) -> String {
        var name = (title ?? "").replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name.unicodeScalars.removeAll { $0.value < 0x20 || $0.value == 0x7F }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        while name.utf8.count > 200 { name.removeLast() }
        let base = name.isEmpty ? "Contact Sheet" : "\(name) Contact Sheet"
        return "\(base).\(format.fileExtension)"
    }
}
