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
        ExportWorker.Request(
            sourceURL: root.appendingPathComponent(record.relPath),
            destinationURL: destination,
            editStackJSON: editStackJSON, userRotation: record.userRotation,
            settings: settings, colorSpace: colorSpace,
            maxLongEdge: resize ? maxLongEdge : nil,
            keywords: includeMetadata ? keywords : [],
            rating: includeMetadata ? record.rating : 0,
            includeMetadata: includeMetadata,
            includeLocation: includeMetadata && includeLocation,
            replacesExisting: collision == .replace)
    }
}
