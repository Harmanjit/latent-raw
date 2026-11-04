import SwiftUI
import Catalog

/// One background job as the Activity popover lists it.
struct ActivityRow: Identifiable {
    enum State: Equatable {
        case running
        /// Held between items by its Pause button.
        case paused
    }

    /// Stable per kind of job: "export", "selection", "thumbnails"…
    let id: String
    /// "Export", "Dust removal", "Thumbnails".
    let title: String
    /// "3 of 12 · DSC_0107.NEF"; empty for nothing to add.
    let detail: String
    /// 0…1, nil when the job can't say how far it has got.
    let fraction: Double?
    let state: State
    /// Pauses or resumes; nil for a job that is one indivisible piece of
    /// work (a Photo Merge, a print) and so has no safe point to pause at.
    let setPaused: ((Bool) -> Void)?
    /// nil when the job can only be waited for (a print, thumbnails).
    let cancel: (() -> Void)?

    var stateLabel: String { state == .paused ? "Paused" : "Running" }
}

/// What is running in the background, gathered from the queues that run
/// it: the export, a Photo Merge or a Remove Dust / Find Faces run (which
/// take turns on the GPU, so at most one of them), thumbnail generation,
/// a watched-folder import, and prints and contact sheets (`OutputJobs`).
/// Nothing queues behind another job in Latent (a job the GPU is busy for
/// is refused rather than queued), so every row is running or paused.
@MainActor
enum BackgroundActivity {
    static func rows(library: Library, exportQueue: ExportQueue, photoMerge: PhotoMergeQueue,
                     selectionJobs: SelectionJobQueue, outputJobs: OutputJobs = .shared,
                     autoImport: AutoImportController? = .shared) -> [ActivityRow] {
        var rows: [ActivityRow] = []
        if exportQueue.isRunning {
            let count = "\(exportQueue.done) of \(exportQueue.total)"
            rows.append(ActivityRow(
                id: "export", title: "Export",
                detail: exportQueue.currentName.isEmpty ? count : "\(count) · \(exportQueue.currentName)",
                fraction: Double(exportQueue.done) / Double(max(exportQueue.total, 1)),
                state: exportQueue.isPaused ? .paused : .running,
                setPaused: { $0 ? exportQueue.pause() : exportQueue.resume() },
                cancel: { exportQueue.cancel() }))
        }
        if selectionJobs.isRunning {
            rows.append(ActivityRow(
                id: "selection", title: selectionJobs.title,
                detail: selectionJobs.progress?.stage ?? "Starting…",
                fraction: selectionJobs.progress?.fraction,
                state: selectionJobs.isPaused ? .paused : .running,
                setPaused: { $0 ? selectionJobs.pause() : selectionJobs.resume() },
                cancel: { selectionJobs.cancel() }))
        }
        if photoMerge.isRunning {
            rows.append(ActivityRow(
                id: "merge", title: photoMerge.kind.title,
                detail: [photoMerge.progress?.stage, photoMerge.name].compactMap { $0 }
                    .filter { !$0.isEmpty }.joined(separator: " · "),
                fraction: photoMerge.progress?.fraction, state: .running,
                setPaused: nil, cancel: { photoMerge.cancel() }))
        }
        if library.thumbnailsTotal > 0, library.thumbnailsDone < library.thumbnailsTotal {
            rows.append(ActivityRow(
                id: "thumbnails", title: "Thumbnails",
                detail: "\(library.thumbnailsDone) of \(library.thumbnailsTotal)",
                fraction: Double(library.thumbnailsDone) / Double(library.thumbnailsTotal),
                state: library.thumbnailsPaused ? .paused : .running,
                setPaused: { library.setThumbnailsPaused($0) }, cancel: nil))
        }
        if let autoImport, autoImport.isImporting {
            rows.append(ActivityRow(id: "autoImport", title: "Watched-folder import", detail: autoImport.status,
                                    fraction: nil, state: .running, setPaused: nil, cancel: nil))
        }
        // Merges, dust removal and face searches register here too; their
        // queues' rows above say more.
        for job in outputJobs.running where job.kind == .print || job.kind == .contactSheet {
            rows.append(ActivityRow(id: job.id.uuidString, title: job.kind == .print ? "Print" : "Contact sheet",
                                    detail: job.name, fraction: nil, state: .running,
                                    setPaused: nil, cancel: job.cancel))
        }
        return rows
    }
}

/// The status bar's Activity button: shown while anything runs in the
/// background, it opens a popover listing each job with its Pause/Resume
/// and Cancel.
struct ActivityStatusButton: View {
    @ObservedObject var library: Library
    @ObservedObject var exportQueue: ExportQueue
    @ObservedObject var photoMerge: PhotoMergeQueue
    @ObservedObject var selectionJobs: SelectionJobQueue
    @ObservedObject private var autoImport = AutoImportController.shared
    @State private var showing = false

    var body: some View {
        let rows = BackgroundActivity.rows(library: library, exportQueue: exportQueue, photoMerge: photoMerge,
                                           selectionJobs: selectionJobs, autoImport: autoImport)
        if !rows.isEmpty {
            let paused = rows.allSatisfy { $0.state == .paused }
            Button { showing.toggle() } label: {
                HStack(spacing: 3) {
                    Image(systemName: paused ? "pause.circle" : "arrow.triangle.2.circlepath")
                    if rows.count > 1 { Text("\(rows.count)").font(.caption2.monospacedDigit()) }
                }
            }
            .controlSize(.small)
            .help(paused ? "Background activity: paused" : "Background activity")
            .accessibilityLabel("Background activity")
            .accessibilityValue(paused ? "\(rows.count) paused" : "\(rows.count) running")
            .popover(isPresented: $showing, arrowEdge: .top) {
                ActivityList(rows: rows).padding(12).frame(width: 300)
            }
        }
    }
}

/// The popover's list.
struct ActivityList: View {
    let rows: [ActivityRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Activity").font(.headline)
            if rows.isEmpty {
                Text("Nothing running").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.title).font(.caption)
                        Text(row.stateLabel).font(.caption2)
                            .foregroundStyle(row.state == .paused ? Color.orange : Color.secondary)
                        Spacer()
                        if let setPaused = row.setPaused {
                            PauseResumeButton(isPaused: row.state == .paused, jobName: row.title, setPaused: setPaused)
                        }
                        if let cancel = row.cancel {
                            Button("Cancel", action: cancel).controlSize(.mini)
                                .accessibilityLabel("Cancel \(row.title.lowercased())")
                        }
                    }
                    if let fraction = row.fraction {
                        ProgressView(value: fraction, total: 1).controlSize(.small)
                            .accessibilityLabel("\(row.title) progress")
                    }
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }
}

/// Pause or Resume for a background job: the library panel's and the
/// Activity popover's.
struct PauseResumeButton: View {
    let isPaused: Bool
    /// For VoiceOver: "Pause export".
    let jobName: String
    let setPaused: (Bool) -> Void

    var body: some View {
        Button(isPaused ? "Resume" : "Pause") { setPaused(!isPaused) }
            .controlSize(.mini)
            .help(isPaused ? "Carry on from the next item"
                  : "Finish the item under way, then wait until Resume")
            .accessibilityLabel("\(isPaused ? "Resume" : "Pause") \(jobName.lowercased())")
    }
}
