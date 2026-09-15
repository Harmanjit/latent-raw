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
    /// regenerated, neural denoise runs, and (as `options` say) camera,
    /// date, keywords, rating and location are written. Rendering the
    /// in-memory parameters directly would skip all of that, because masks
    /// and denoise results are computed state the edit doesn't carry.
    ///
    /// The edit is encoded here from the current parameters, exactly as
    /// a save would store it, rather than read back from the catalog: an
    /// edit made a moment ago may not have been saved yet. `rating` and
    /// `readKeywords` come from the caller because they live in the
    /// catalog, which the editor doesn't own.
    ///
    /// Everything the file is made from (raw, edit, rotation, settings) is
    /// taken before anything waits, and `isExporting` is set at once, so a
    /// slow keyword read can neither let another image's pixels into this
    /// file nor let a second export start.
    ///
    /// The worker opens its own copy of the raw file, so the viewport's
    /// session is untouched; only the Sendable request and the GPU
    /// context cross over.
    func export(to destination: URL, options: OpenImageExportOptions, rating: Int,
                readKeywords: (@Sendable () async throws -> [String])?) {
        guard let gpuContext, let sourceURL, !isExporting else { return }
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
            rating: options.includeMetadata ? rating : 0,
            includeMetadata: options.includeMetadata,
            includeLocation: options.includeMetadata && options.includeLocation,
            // The Save panel asked before replacing a file that was there.
            // One that appears under the name during the render is kept.
            replacesExisting: FileManager.default.fileExists(atPath: destination.path))

        isExporting = true
        status = "Exporting at full resolution…"

        Task {
            var complete = request
            if options.includeMetadata, let readKeywords {
                do {
                    complete.keywords = try await readKeywords()
                } catch {
                    // Exporting without them would silently drop metadata.
                    isExporting = false
                    status = "Export cancelled"
                    reportFailure("Reading keywords for export", error)
                    return
                }
            }
            let ready = complete
            // Detached so the masks and render run off the main actor, as
            // the queue's do.
            let outcome: Result<ExportWorker.Outcome, Error> = await Task.detached(priority: .userInitiated) {
                do { return .success(try await ExportWorker.export(ready, gpu: gpuContext)) }
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

    /// Returns once no Export Open Image is under way (at once when none
    /// is), with its file written or its export failed. For quitting, so a
    /// short poll is plenty; the export's task isn't kept anywhere to await.
    func waitForExport() async {
        while isExporting {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// Export Open Image's metadata switches, the export sheet's two in the
/// left panel, remembered in preferences. Metadata is on and location off
/// until changed, as in a new export preset.
struct OpenImageExportOptions: Equatable {
    static let includeMetadataKey = "latent.exportOpenImage.includeMetadata"
    static let includeLocationKey = "latent.exportOpenImage.includeLocation"
    var includeMetadata = true
    /// Only counts with `includeMetadata`.
    var includeLocation = false

    static func load(from defaults: UserDefaults = .standard) -> OpenImageExportOptions {
        OpenImageExportOptions(includeMetadata: defaults.object(forKey: includeMetadataKey) as? Bool ?? true,
                               includeLocation: defaults.object(forKey: includeLocationKey) as? Bool ?? false)
    }
}
