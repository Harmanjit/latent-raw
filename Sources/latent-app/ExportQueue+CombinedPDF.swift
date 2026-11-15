import Foundation
import PixelEngine
import Catalog
import MLKit

// Export › PDF › Combine into one PDF: the whole selection as the pages of
// a single file (CombinedPDFWriter), through the same queue, progress,
// pause and cancel as any export. One file, so the per-photo naming plan
// isn't used: the file is named once, by `combinedPDFStem`, and the
// collision policy settles that one name.

extension ExportPreset {
    /// A PDF export with Combine into one PDF on.
    var combinesPDF: Bool { fileKind == .pdf && formats.pdf.combine }

    /// The combined file's name without extension: the name typed in the
    /// sheet, else the catalog's folder name, cleaned of path characters.
    func combinedPDFStem(catalogName: String) -> String {
        let typed = formats.pdf.combinedFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = ExportBatchPlanner.Options.cleanSubfolder(typed.isEmpty ? catalogName : typed)
        return stem.isEmpty ? "Photos" : stem
    }

    /// The folder the combined file goes in: the destination, or the
    /// sheet's subfolder of it.
    func combinedPDFFolder(destination: URL) -> URL {
        let subfolder = ExportBatchPlanner.Options.cleanSubfolder(subfolder)
        return subfolder.isEmpty ? destination : destination.appendingPathComponent(subfolder, isDirectory: true)
    }

    /// Where the combined file is written, settled by the collision policy
    /// against `exists`: Add a number numbers it ("Shoot-1.pdf"…), Replace
    /// (and Overwrite if edit changed, which has no single edit to compare)
    /// replaces, Skip gives nil when the name is taken.
    static func combinedPDFTarget(folder: URL, stem: String, fileExtension: String,
                                  collision: ExportNaming.Collision,
                                  exists: (URL) -> Bool) -> (url: URL, replaces: Bool)? {
        let name = stem + "." + fileExtension
        let url = folder.appendingPathComponent(name)
        guard exists(url) else { return (url, false) }
        switch collision {
        case .skip: return nil
        case .replace, .replaceIfChanged: return (url, true)
        case .addNumber:
            for n in 1...9999 {
                let candidate = folder.appendingPathComponent(ExportNaming.numbered(name, n))
                if !exists(candidate) { return (candidate, false) }
            }
            return nil
        }
    }

    /// The caption under one photo of a combined PDF: the caption template
    /// when one is set, else, on a contact sheet, the file name.
    func combinedPDFCaption(for record: ImageRecord, index: Int, catalogName: String) -> String? {
        if let caption = pdfJob(for: record, index: index, catalogName: catalogName)?.caption, !caption.isEmpty {
            return caption
        }
        return formats.pdf.combinedLayout == .contactSheet ? record.fileName : nil
    }
}

extension ExportQueue {
    /// What a combined batch reports back to the queue, on the main actor.
    enum CombinedPDFEvent: Sendable {
        case current(String)
        case photoDone
        case failure(name: String, reason: String)
        case note(String)
    }

    /// How a combined batch ended.
    struct CombinedPDFOutcome: Sendable {
        /// The file written, nil when none was (cancelled, skipped, failed).
        var url: URL?
        var photos = 0
        var pixels = 0
        var skipped = false
        var substituted = 0
    }

    /// Renders every record into one PDF. Checks for cancel and pause
    /// before each photo as the per-file loop does; a cancelled run leaves
    /// no file. Each photo counts one step of the queue's progress.
    nonisolated static func runCombinedPDF(
        records: [ImageRecord], preset: ExportPreset, destination: URL, root: URL, catalog: Catalog,
        catalogName: String, batchName: String?, gpu: GPUContext, pauseGate: PauseGate,
        report: @escaping @MainActor @Sendable (CombinedPDFEvent) -> Void
    ) async -> CombinedPDFOutcome {
        var outcome = CombinedPDFOutcome()
        let options = preset.formats.pdf
        let folder = preset.combinedPDFFolder(destination: destination)
        let stem = preset.combinedPDFStem(catalogName: catalogName)
        let label = batchName.map { "\(stem).pdf (\($0))" } ?? "\(stem).pdf"
        let ext = preset.uppercaseExtension ? "PDF" : "pdf"
        let collision = preset.collision
        let target: (url: URL, replaces: Bool)?
        let writer: CombinedPDFWriter
        do {
            let settled = try await Task.detached(priority: .userInitiated) { () throws -> ((url: URL, replaces: Bool)?, CombinedPDFWriter?) in
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                guard let target = ExportPreset.combinedPDFTarget(
                    folder: folder, stem: stem, fileExtension: ext, collision: collision,
                    exists: { FileManager.default.fileExists(atPath: $0.path) }) else { return (nil, nil) }
                return (target, try CombinedPDFWriter(url: target.url, options: options, title: stem))
            }.value
            guard let made = settled.1 else {
                outcome.skipped = true
                for _ in records { await report(.photoDone) }
                return outcome
            }
            target = settled.0
            writer = made
        } catch {
            await report(.failure(name: label, reason: "could not create the PDF: \(error)"))
            for _ in records { await report(.photoDone) }
            return outcome
        }
        let resolution = Double(preset.ppiEnabled ? min(max(preset.ppi, 1), 9999) : 300)
        let maxLongEdge = options.combinedMaxLongEdge(ppi: resolution)
        var cancelled = false
        for (index, record) in records.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            if await pauseGate.waitWhilePaused(), Task.isCancelled { cancelled = true; break }
            let name = batchName.map { "\(record.fileName) (\($0))" } ?? record.fileName
            await report(.current(name))
            let json: String?
            let keywords: [String]
            do {
                json = try await catalog.editStack(forImageID: record.id ?? -1)
                keywords = try await catalog.keywords(forImageID: record.id ?? -1)
            } catch {
                await report(.failure(name: name, reason: "could not read its edit: \(error)"))
                await report(.photoDone)
                continue
            }
            let request = preset.workerRequest(for: record, root: root, destination: target?.url ?? folder,
                                               editStackJSON: json, keywords: keywords)
            let caption = preset.combinedPDFCaption(for: record, index: index, catalogName: catalogName)
            let result: Result<(pixels: Int, substitutions: [String]), Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let image = try await ExportWorker.renderImage(
                        ExportWorker.ImageRequest(sourceURL: request.sourceURL, editStackJSON: request.editStackJSON,
                                                  userRotation: request.userRotation, colorSpace: request.colorSpace,
                                                  maxLongEdge: maxLongEdge, bitsPerComponent: 8),
                        gpu: gpu)
                    writer.add(image.cgImage, caption: caption, ppi: resolution)
                    return .success((image.cgImage.width * image.cgImage.height, image.maskSubstitutions))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let r):
                outcome.photos += 1
                outcome.pixels += r.pixels
                if !r.substitutions.isEmpty {
                    outcome.substituted += 1
                    await report(.note(MaskSubstitutions.exportNote(name: name, missing: r.substitutions)))
                }
            case .failure(let error):
                await report(.failure(name: name, reason: "\(error)"))
            }
            await report(.photoDone)
        }
        if cancelled || outcome.photos == 0 {
            writer.discard()
            outcome.photos = 0
            return outcome
        }
        let replaces = target?.replaces ?? false
        do {
            outcome.url = try await Task.detached(priority: .userInitiated) {
                try writer.finish(replacingExisting: replaces)
            }.value
        } catch {
            outcome.photos = 0
            await report(.failure(name: label, reason: "could not save the PDF: \(error)"))
        }
        return outcome
    }
}
