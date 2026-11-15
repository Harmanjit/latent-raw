import Foundation
import CoreGraphics
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

    /// One photo of a combined PDF, ready for a worker.
    struct CombinedPage: Sendable {
        var name: String
        var request: ExportWorker.Request
        var caption: String?
    }

    /// A photo rendered for its page: the image the page stores.
    struct RenderedPage: @unchecked Sendable {
        // CGImage is immutable; @unchecked only for older SDKs that don't
        // mark it Sendable.
        var image: CGImage
        var pixels: Int
        var substitutions: [String]
    }

    struct CombinedPageResult: Sendable {
        var name: String
        var caption: String?
        var result: Result<RenderedPage, Error>
    }

    /// A photo whose edit couldn't be read, for its failure's wording.
    struct EditUnreadable: Error {
        var error: Error
    }

    /// Renders every record into one PDF, `workers` photos at a time, the
    /// pages in the records' order. Checks for cancel and pause before each
    /// photo as the per-file loop does; a cancelled run leaves no file.
    /// Each photo counts one step of the queue's progress.
    nonisolated static func runCombinedPDF(
        records: [ImageRecord], preset: ExportPreset, destination: URL, root: URL, catalog: Catalog,
        catalogName: String, batchName: String?, gpu: GPUContext, pauseGate: PauseGate, workers: Int = 1,
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
        let jpegQuality = preset.pdfJPEGQuality
        var cancelled = false
        var nextIndex = 0
        // Photos render `workers` at a time (ExportPipeline); each is made
        // into its page image (a JPEG, unless the pages are lossless) on its
        // worker too, and the pages go into the file in the selection's
        // order as the photos are committed.
        await ExportPipeline.run(
            workers: workers,
            hold: { pauseGate.isPaused },
            next: { () async -> ExportPipeline.Step<CombinedPage, CombinedPageResult>? in
                guard nextIndex < records.count else { return nil }
                if Task.isCancelled { cancelled = true; return nil }
                if await pauseGate.waitWhilePaused(), Task.isCancelled { cancelled = true; return nil }
                let index = nextIndex
                nextIndex += 1
                let record = records[index]
                let name = batchName.map { "\(record.fileName) (\($0))" } ?? record.fileName
                await report(.current(name))
                let json: String?
                let keywords: [String]
                do {
                    json = try await catalog.editStack(forImageID: record.id ?? -1)
                    keywords = try await catalog.keywords(forImageID: record.id ?? -1)
                } catch {
                    return .done(CombinedPageResult(name: name, result: .failure(EditUnreadable(error: error))))
                }
                let request = preset.workerRequest(for: record, root: root, destination: target?.url ?? folder,
                                                   editStackJSON: json, keywords: keywords)
                let caption = preset.combinedPDFCaption(for: record, index: index, catalogName: catalogName)
                return .run(CombinedPage(name: name, request: request, caption: caption))
            },
            work: { page in
                do {
                    let image = try await ExportWorker.renderImage(
                        ExportWorker.ImageRequest(sourceURL: page.request.sourceURL,
                                                  editStackJSON: page.request.editStackJSON,
                                                  userRotation: page.request.userRotation,
                                                  colorSpace: page.request.colorSpace,
                                                  maxLongEdge: maxLongEdge, bitsPerComponent: 8),
                        gpu: gpu)
                    let stored = options.pageImage(image.cgImage, jpegQuality: jpegQuality)
                    return CombinedPageResult(name: page.name, caption: page.caption,
                                              result: .success(RenderedPage(image: stored,
                                                                            pixels: image.cgImage.width * image.cgImage.height,
                                                                            substitutions: image.maskSubstitutions)))
                } catch {
                    return CombinedPageResult(name: page.name, result: .failure(error))
                }
            },
            commit: { page in
                switch page.result {
                case .success(let r):
                    writer.add(r.image, caption: page.caption, ppi: resolution)
                    outcome.photos += 1
                    outcome.pixels += r.pixels
                    if !r.substitutions.isEmpty {
                        outcome.substituted += 1
                        await report(.note(MaskSubstitutions.exportNote(name: page.name, missing: r.substitutions)))
                    }
                case .failure(let error as EditUnreadable):
                    await report(.failure(name: page.name, reason: "could not read its edit: \(error.error)"))
                case .failure(let error):
                    await report(.failure(name: page.name, reason: "\(error)"))
                }
                await report(.photoDone)
            })
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
