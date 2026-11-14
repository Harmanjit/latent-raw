import Foundation
import PixelEngine
import Catalog
import MLKit

extension ExportPreset {
    /// What the Export Open Image watermark switch does, for its tooltip.
    static let openImageWatermarkHelp = "Stamps the watermark set up in the Export sheet (its text, corner, size, "
        + "opacity and colour) into the file."

    /// The worker request for one image of a batch. The queue, the size
    /// estimate and the quality comparison all build it here, so what the
    /// sheet measures is what the export writes.
    func workerRequest(for record: ImageRecord, root: URL, destination: URL, editStackJSON: String?,
                       keywords: [String]) -> ExportWorker.Request {
        var request = ExportWorker.Request(
            sourceURL: root.appendingPathComponent(record.fileRelPath),
            destinationURL: destination,
            editStackJSON: editStackJSON, userRotation: record.userRotation,
            settings: settings, colorSpace: colorSpace,
            maxLongEdge: resize ? maxLongEdge : nil,
            keywords: includeMetadata ? keywords : [],
            rating: includeMetadata ? record.rating : 0,
            includeMetadata: includeMetadata,
            includeLocation: includeMetadata && includeLocation,
            replacesExisting: collision == .replace)
        if includeMetadata { request.descriptive = record.exportDescription }
        if let mark = request.settings.watermark {
            request.settings.watermark = Self.watermark(mark, filledFor: record, keywords: keywords,
                                                        catalogName: root.lastPathComponent)
        }
        request.sizing = sizing
        request.sizeLimitBytes = sizeLimitBytes
        request.metadataLevel = metadataLevel
        return request
    }

    /// The watermark with the naming tokens ({lens}, {iso}, {title},
    /// {date:yyyy}, with their modifiers; ExportNaming) filled in for one
    /// photo. {year} and {name} are left for the export worker, which has
    /// always filled them, so a watermark using them comes out as before.
    static func watermark(_ mark: ExportWatermark, filledFor record: ImageRecord, keywords: [String],
                          catalogName: String) -> ExportWatermark {
        guard mark.style == .text, mark.text.contains("{") else { return mark }
        let kept = [("{year}", "\u{E010}"), ("{name}", "\u{E011}")]
        var template = mark.text
        for (token, stand) in kept {
            template = template.replacingOccurrences(of: token, with: stand, options: .caseInsensitive)
        }
        var context = ExportNaming.Context(index: 0, catalogName: catalogName)
        context.keywords = keywords
        var text = ExportNaming.text(template: template, record: record, context: context)
        for (token, stand) in kept { text = text.replacingOccurrences(of: stand, with: token) }
        var filled = mark
        filled.text = text
        return filled
    }
}
