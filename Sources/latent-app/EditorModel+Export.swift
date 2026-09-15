import SwiftUI
import PixelEngine
import MLKit

extension EditorModel {
    // MARK: - Export

    /// Asks where to write the open image. Returns nil if there's no image
    /// or the user cancelled.
    func chooseExportDestination() -> URL? {
        guard hasImage, let sourceURL else { return nil }

        let panel = NSSavePanel()
        panel.message = "Export image"
        panel.allowedContentTypes = [exportSettings.format.contentType]
        panel.nameFieldStringValue = sourceURL
            .deletingPathExtension().lastPathComponent
            + "." + exportSettings.format.fileExtension

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    /// Exports the open image through `ExportWorker`, the code the export
    /// queue runs and the golden-image tests check, so this file and a
    /// queued export of the same image are identical: AI masks are
    /// regenerated, neural denoise runs, and camera, date, keywords and
    /// rating are written. Rendering the in-memory parameters directly
    /// would skip all of that, because masks and denoise results are
    /// computed state the edit doesn't carry.
    ///
    /// The edit is encoded here from the current parameters, exactly as
    /// a save would store it, rather than read back from the catalog: an
    /// edit made a moment ago may not have been saved yet. `keywords` and
    /// `rating` come from the caller because they live in the catalog,
    /// which the editor doesn't own.
    ///
    /// The worker opens its own copy of the raw file, so the viewport's
    /// session is untouched; only the Sendable request and the GPU
    /// context cross over.
    func export(to destination: URL, keywords: [String], rating: Int) {
        guard let gpuContext, let sourceURL else { return }
        let editStackJSON: String?
        do {
            editStackJSON = EditStack.isDefault(parameters, relativeTo: defaultParameters)
                ? nil : try stackWithProvenance().encodeJSON()
        } catch {
            reportFailure("Encoding the edit for export", error)
            return
        }
        // Let the catalog catch up too, as the queue's caller does, so the
        // stored edit matches the file just written.
        flushPendingSave()

        let request = ExportWorker.Request(
            sourceURL: sourceURL, destinationURL: destination,
            editStackJSON: editStackJSON, userRotation: userRotation,
            settings: exportSettings,
            // This export has no colour space picker; sRGB is the safe
            // default, and what it has always written.
            colorSpace: .sRGB, maxLongEdge: nil,
            keywords: keywords, rating: rating, includeMetadata: true)

        isExporting = true
        status = "Exporting at full resolution…"

        Task {
            // Detached so the masks and render run off the main actor, as
            // the queue's do.
            let outcome: Result<ExportWorker.Outcome, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try await ExportWorker.export(request, gpu: gpuContext)) }
                catch { return .failure(error) }
            }.value
            isExporting = false
            switch outcome {
            case .success(let o):
                status = String(format: "Exported %@ in %.1fs",
                                destination.lastPathComponent, o.seconds)
            case .failure(let error):
                status = "Export failed: \(error)"
            }
        }
    }
}
