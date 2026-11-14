import Foundation
import PixelEngine
import ColorKit
import Catalog

/// The units the export sheet's sizing row can be typed in. Pixels are
/// what the preset keeps; centimetres and inches are shown and typed
/// through the Resolution (ppi) value, and converted to pixels before the
/// export's sizing is built, so nothing downstream sees them.
enum ExportSizeUnit: String, Codable, CaseIterable, Sendable {
    case pixels, centimetres, inches

    var title: String {
        switch self {
        case .pixels: "px"
        case .centimetres: "cm"
        case .inches: "in"
        }
    }

    /// Pixels per one of this unit at `ppi`.
    func pixelsPerUnit(ppi: Int) -> Double {
        let ppi = Double(min(max(ppi, 1), 9999))
        switch self {
        case .pixels: return 1
        case .centimetres: return ppi / 2.54
        case .inches: return ppi
        }
    }

    /// `pixels` in this unit.
    func value(pixels: Int, ppi: Int) -> Double { Double(pixels) / pixelsPerUnit(ppi: ppi) }

    /// `value` of this unit in whole pixels, at least one.
    func pixels(value: Double, ppi: Int) -> Int {
        guard value.isFinite else { return 1 }
        return max(1, min(Int((value * pixelsPerUnit(ppi: ppi)).rounded()), 1_000_000))
    }
}

/// The export options added with borders, the PDF and OpenEXR formats,
/// deeper PNG, HEIC and TIFF files, the rendering intent, physical sizes
/// and the metadata extras. Kept as one value in the preset so a preset
/// saved before them (which lacks the key) decodes to these defaults, and
/// every default is what an export did before the option existed.
struct ExportFormatOptions: Codable, Equatable, Sendable {
    var borderEnabled = false
    var border = ExportBorder()
    /// 8 or 16; 8, as PNG always was.
    var pngBitDepth = 8
    /// 8 or 10.
    var heicBitDepth = 8
    var greyscaleWhenMonochrome = false
    var exr = EXROptions()
    var pdf = ExportPDFOptions()
    var sizeUnit: ExportSizeUnit = .pixels
    /// Nil keeps the intent a conversion always used
    /// (`ExportColorProfile.defaultIntent(for:)`).
    var renderingIntent: RenderingIntent?
    var keywordHierarchy = false
    var embedEdit = false

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportFormatOptions()
        borderEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .borderEnabled)) ?? d.borderEnabled
        border = (try? c.decodeIfPresent(ExportBorder.self, forKey: .border)) ?? d.border
        pngBitDepth = (try? c.decodeIfPresent(Int.self, forKey: .pngBitDepth)) == 16 ? 16 : 8
        heicBitDepth = (try? c.decodeIfPresent(Int.self, forKey: .heicBitDepth)) == 10 ? 10 : 8
        greyscaleWhenMonochrome = (try? c.decodeIfPresent(Bool.self, forKey: .greyscaleWhenMonochrome)) ?? false
        exr = (try? c.decodeIfPresent(EXROptions.self, forKey: .exr)) ?? d.exr
        pdf = (try? c.decodeIfPresent(ExportPDFOptions.self, forKey: .pdf)) ?? d.pdf
        sizeUnit = (try? c.decodeIfPresent(ExportSizeUnit.self, forKey: .sizeUnit)) ?? .pixels
        renderingIntent = (try? c.decodeIfPresent(RenderingIntent.self, forKey: .renderingIntent)) ?? nil
        keywordHierarchy = (try? c.decodeIfPresent(Bool.self, forKey: .keywordHierarchy)) ?? false
        embedEdit = (try? c.decodeIfPresent(Bool.self, forKey: .embedEdit)) ?? false
    }
}

/// What a PDF export's file needs beyond the worker request: the page
/// layout, the caption made for this photo, the resolution and the size
/// to render at.
struct ExportPDFJob: Sendable {
    var options = ExportPDFOptions()
    var caption: String?
    var ppi: Double = 300
    var maxLongEdge: Int?
}

extension ExportPreset {
    /// The settings these options add; the defaults add nothing.
    func applyFormatOptions(to s: inout ExportSettings) {
        s.pngBitDepth = formats.pngBitDepth
        s.heicBitDepth = formats.heicBitDepth
        s.greyscaleWhenMonochrome = formats.greyscaleWhenMonochrome
        s.exr = formats.exr
        if formats.borderEnabled, formats.border.isActive { s.border = formats.border }
        if let intent = formats.renderingIntent, var profile = s.colorProfile {
            profile.intent = intent
            s.colorProfile = profile
        }
        // At the None level there is no metadata at all, so nothing to add to.
        s.keywordHierarchy = includeMetadata && formats.keywordHierarchy
        s.embedsEdit = includeMetadata && formats.embedEdit
    }

    /// The PDF part of one photo's job; nil unless this is a PDF export.
    func pdfJob(for record: ImageRecord, index: Int, catalogName: String) -> ExportPDFJob? {
        guard fileKind == .pdf else { return nil }
        let options = formats.pdf
        let template = options.captionTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        var caption: String?
        if !template.isEmpty {
            let context = ExportNaming.Context(index: index, start: sequenceStart, padding: sequencePadding,
                                               catalogName: catalogName, step: sequenceStep)
            caption = ExportNaming.Namer(template: template).stem(for: record, context: context)
        }
        let resolution = Double(ppiEnabled ? min(max(ppi, 1), 9999) : 300)
        // A paper page needs no more pixels than it holds at the resolution;
        // Fit to image is the photo at full size.
        let maxLongEdge = options.pageSize.portraitPoints.map {
            Int((max($0.width, $0.height) / 72 * resolution).rounded(.up))
        }
        return ExportPDFJob(options: options, caption: caption, ppi: resolution, maxLongEdge: maxLongEdge)
    }
}

extension ExportSizing.Mode {
    /// Whether the mode is sized by lengths (which can be typed in cm or
    /// inches), not megapixels or a percentage.
    var usesLengths: Bool {
        switch self {
        case .megapixels, .percentage: false
        default: true
        }
    }
}
