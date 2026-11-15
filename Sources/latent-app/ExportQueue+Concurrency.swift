import Foundation
import Metal
import SwiftUI
import PixelEngine
import Catalog
import MLKit

// Export › Photos at once: how many photos an export works on together
// (ExportPipeline, ExportConcurrency in MLKit; docs/Performance-Plan.md
// #19). The choice is the Mac's, not a preset's: it's kept on its own in
// UserDefaults, so saved presets and Export with Previous are untouched.

enum ExportPhotosAtOnce {
    static let defaultsKey = "latent.exportPhotosAtOnce"

    /// The saved choice: `ExportConcurrency.automaticChoice` (0) for
    /// Automatic, else a count.
    static func load(defaults: UserDefaults = .standard) -> Int {
        max(defaults.integer(forKey: defaultsKey), ExportConcurrency.automaticChoice)
    }

    static func save(_ choice: Int, defaults: UserDefaults = .standard) {
        defaults.set(max(choice, ExportConcurrency.automaticChoice), forKey: defaultsKey)
    }

    /// This Mac, once: its memory, the GPU's working set and its cores
    /// don't change while the app runs.
    static let machine = ExportConcurrency.Machine.current(device: MTLCreateSystemDefaultDevice())

    /// The biggest photo of `records`, in megapixels.
    static func sourceMegapixels(_ records: [ImageRecord]) -> Double {
        records.map {
            ExportConcurrency.estimatedMegapixels(width: $0.width, height: $0.height, fileBytes: $0.size)
        }.max() ?? 24
    }

    /// The megapixels of the file `preset` makes from a photo of
    /// `source` megapixels (3:2 assumed where only a long edge is known).
    static func outputMegapixels(preset: ExportPreset, source: Double) -> Double {
        let aspect = 1.5
        let height = (source * 1_000_000 / aspect).squareRoot()
        let width = height * aspect
        func fromLongEdge(_ edge: Int?) -> Double {
            guard let edge, Double(edge) < width else { return source }
            let e = Double(edge)
            return e * (e / aspect) / 1_000_000
        }
        switch preset.fileKind {
        case .original:
            return 0
        case .dng:
            return source
        case .pdf:
            let ppi = Double(preset.ppiEnabled ? min(max(preset.ppi, 1), 9999) : 300)
            return fromLongEdge(preset.formats.pdf.combinedMaxLongEdge(ppi: ppi))
        case .image:
            if let sizing = preset.sizing {
                return fromLongEdge(sizing.targetLongEdge(width: Int(width), height: Int(height)))
            }
            return fromLongEdge(preset.resize ? preset.maxLongEdge : nil)
        }
    }

    /// The most photos at once for this batch on this Mac.
    static func limit(records: [ImageRecord], preset: ExportPreset,
                      machine: ExportConcurrency.Machine = machine) -> Int {
        let source = sourceMegapixels(records)
        return ExportConcurrency.limit(machine: machine, sourceMegapixels: source,
                                       outputMegapixels: outputMegapixels(preset: preset, source: source))
    }

    /// The control's help: what the limit is and where it comes from.
    static func help(limit: Int) -> String {
        "Your Mac can export up to \(limit) photo\(limit == 1 ? "" : "s") at a time, worked out from its memory, "
            + "its graphics processor and the size of these photos. More at once is faster until the graphics "
            + "processor is busy all the time; Automatic picks the count that measured best."
    }
}

extension ExportQueue {
    /// How many photos a batch runs at once, and what the progress says
    /// about it.
    struct Concurrency: Equatable, Sendable {
        var workers: Int
        var limit: Int
        /// The saved choice was more than this batch's limit.
        var clamped: Bool
        var choice: Int

        /// Said quietly under the progress: only when the choice had to be
        /// lowered for these photos.
        var note: String {
            guard clamped else { return "" }
            return "\(workers) at a time: \(choice) is more than this Mac can take for these photos"
        }
    }

    nonisolated static func concurrency(records: [ImageRecord], preset: ExportPreset, choice: Int,
                                        machine: ExportConcurrency.Machine = ExportPhotosAtOnce.machine) -> Concurrency {
        let limit = ExportPhotosAtOnce.limit(records: records, preset: preset, machine: machine)
        let resolved = ExportConcurrency.resolve(choice: choice, limit: limit)
        return Concurrency(workers: resolved.workers, limit: limit, clamped: resolved.clamped, choice: choice)
    }

    func applyConcurrency(_ concurrency: Concurrency) {
        photosAtOnce = concurrency.workers
        concurrencyNote = concurrency.note
    }

    /// One photo on its way through the pipeline: what `next` settled for
    /// it, kept so a retry can render it again under another name.
    struct PhotoJob: Sendable {
        var index: Int
        var name: String
        var record: ImageRecord
        var target: URL
        var json: String?
        var keywords: [String]
        var sidecar: XMPSidecar.Fields?
        /// Renders so far, the one under way included.
        var attempts = 1
    }

    struct PreparedPhoto: Sendable {
        var photo: PhotoJob
        var job: ExportFileJob
    }

    /// What became of one photo, committed in the batch's order.
    enum PhotoOutcome: Sendable {
        case finished(PhotoJob, Result<ExportFileResult, Error>)
        case skipped(name: String)
        case failed(name: String, reason: String)

        var name: String {
            switch self {
            case .finished(let photo, _): photo.name
            case .skipped(let name), .failed(let name, _): name
            }
        }
    }

    /// A worker's part: render and write one file, off the main actor.
    nonisolated static func export(_ prepared: PreparedPhoto, gpu: GPUContext) async -> PhotoOutcome {
        do {
            return .finished(prepared.photo, .success(try await prepared.job.run(gpu: gpu)))
        } catch {
            return .finished(prepared.photo, .failure(error))
        }
    }
}

extension ExportPreset {
    /// The work for one photo of a per-file export, at `photo.target`.
    func fileJob(for photo: ExportQueue.PhotoJob, root: URL, catalogName: String) -> ExportFileJob {
        let request = workerRequest(for: photo.record, root: root, destination: photo.target,
                                    editStackJSON: photo.json, keywords: photo.keywords)
        var job = ExportFileJob(kind: fileKind, request: request, sourceHash: photo.record.hashString,
                                captureTime: photo.record.captureTime ?? 0, sidecar: photo.sidecar)
        job.dngContent = dngContent
        job.pdf = pdfJob(for: photo.record, index: photo.index, catalogName: catalogName)
        return job
    }
}

/// The export sheet's Photos at once: Automatic (the measured-best count
/// within the limit) or 1 up to what this Mac can take for these photos.
struct ExportPhotosAtOnceSection: View {
    @Binding var choice: Int
    let limit: Int

    var body: some View {
        HStack {
            Picker("Photos at once", selection: $choice) {
                Text("Automatic (recommended: \(ExportConcurrency.automatic(limit: limit)))")
                    .tag(ExportConcurrency.automaticChoice)
                ForEach(1...max(limit, 1), id: \.self) { Text("\($0)").tag($0) }
                // A count saved for smaller photos stays chosen; the
                // export lowers it and says so under the progress.
                if choice > max(limit, 1) {
                    Text("\(choice) (lowered to \(limit) for these photos)").tag(choice)
                }
            }
            .frame(width: 320)
            .help(ExportPhotosAtOnce.help(limit: limit))
            Spacer()
        }
        Text("Your Mac can export up to \(limit) photo\(limit == 1 ? "" : "s") at a time.")
            .font(.caption).foregroundStyle(.secondary)
    }
}
