import SwiftUI
import AppKit
import Catalog

/// Photo › Verify Files… and Photo › Find Duplicates… (FileIntegrity in
/// Catalog does the work; this runs it and shows what it found).
///
/// Verifying reads every file in full, so it runs in the background with
/// its progress and Cancel in the library panel, registered with
/// `OutputJobs` like the other jobs that read files: the Mac stays awake,
/// quitting asks first, and Rename and Move wait, since a file moved
/// mid-run would read as missing. It needs no GPU, so it doesn't take the
/// export queue's slot. Results are recorded when the run ends, cancelled
/// or not, for the files already read.
@MainActor
final class FileIntegrityModel: ObservableObject {
    static let shared = FileIntegrityModel()

    @Published private(set) var isRunning = false
    @Published private(set) var fraction = 0.0
    /// "File 3 of 120: DSC_0107.NEF".
    @Published private(set) var stage = ""
    /// The last run's one-line summary, for the panel.
    @Published private(set) var summary = ""
    /// The last run's report, shown as a sheet when it ends.
    @Published var verificationSheet: VerificationSheetItem?
    /// Find Duplicates' sheet.
    @Published var duplicatesSheet: DuplicatesSheetItem?

    let jobs: OutputJobs
    private var task: Task<Void, Never>?

    init(jobs: OutputJobs = .shared) {
        self.jobs = jobs
    }

    struct VerificationSheetItem: Identifiable {
        let id = UUID()
        let report: FileVerificationReport
    }

    struct DuplicatesSheetItem: Identifiable {
        let id = UUID()
        let exact: [DuplicateFinder.Group]
        let near: [DuplicateFinder.Group]
    }

    // MARK: Verify

    /// Verifies the selection, or the whole folder when nothing is
    /// selected. Returns false, doing nothing, while a run is under way or
    /// there is nothing to read.
    @discardableResult
    func startVerifying(library: Library, showsSheet: Bool = true) -> Bool {
        let targets = library.verificationTargets()
        guard !isRunning, !targets.isEmpty, let catalog = library.catalog else { return false }
        let files = targets.compactMap { record in library.fileURL(for: record).map { (record, $0) } }
        isRunning = true
        fraction = 0
        stage = "Starting…"
        summary = ""
        let job = jobs.begin(.verifyFiles, name: targets.count == 1 ? targets[0].fileName : "\(targets.count) files",
                             cancel: { [weak self] in self?.cancel() })
        let started = Date()
        task = Task {
            let worker = Task.detached(priority: .utility) { [weak self] () -> ([FileIntegrity.Check], Bool) in
                var checks: [FileIntegrity.Check] = []
                for (index, (record, url)) in files.enumerated() {
                    if Task.isCancelled { return (checks, true) }
                    let stage = "File \(index + 1) of \(files.count): \(record.fileName)"
                    let fraction = Double(index) / Double(files.count)
                    await MainActor.run { [weak self] in
                        self?.fraction = fraction
                        self?.stage = stage
                    }
                    checks.append(FileIntegrity.check(record, fileURL: url))
                }
                return (checks, false)
            }
            let (checks, cancelled) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            let report = FileVerificationReport(checks: checks, cancelled: cancelled,
                                                elapsed: Date().timeIntervalSince(started), planned: files.count)
            // Inside `perform`, so quitting waits for the write and a
            // failure reaches the status bar.
            library.perform("Verify Files") {
                try await library.recordVerification(checks, in: catalog)
            }
            summary = report.summary
            isRunning = false
            jobs.end(job)
            let damaged = report.with(.damaged).count
            Announcement.post(damaged == 0 ? report.summary
                              : "\(damaged) damaged file\(damaged == 1 ? "" : "s") found")
            if showsSheet, !cancelled { verificationSheet = VerificationSheetItem(report: report) }
        }
        return true
    }

    func cancel() {
        task?.cancel()
    }

    func waitUntilDone() async {
        await task?.value
    }

    // MARK: Duplicates

    func showDuplicates(library: Library) {
        let groups = library.duplicateGroups()
        duplicatesSheet = DuplicatesSheetItem(exact: groups.exact, near: groups.near)
    }
}

// MARK: - Library panel

/// The run under way, with its Cancel, and the last run's summary. In the
/// library panel beside the other jobs.
struct FileVerificationProgressView: View {
    @ObservedObject var model = FileIntegrityModel.shared

    var body: some View {
        if model.isRunning {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Verifying files").font(.caption2)
                    Spacer()
                    Button("Cancel") { model.cancel() }
                        .controlSize(.mini)
                        .accessibilityLabel("Cancel file verification")
                }
                ProgressView(value: model.fraction, total: 1)
                    .controlSize(.small)
                    .accessibilityLabel("File verification progress")
                    .accessibilityValue("\(Int((model.fraction * 100).rounded())) percent")
                Text(model.stage).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityHidden(true)
            }
        } else if !model.summary.isEmpty {
            Text(model.summary).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Sheets

extension View {
    /// The Verify Files report and the Find Duplicates sheet.
    func fileIntegritySheets(library: Library) -> some View {
        modifier(FileIntegritySheets(library: library))
    }
}

private struct FileIntegritySheets: ViewModifier {
    @ObservedObject var model = FileIntegrityModel.shared
    let library: Library

    func body(content: Content) -> some View {
        content
            .sheet(item: $model.verificationSheet) { item in
                FileVerificationSheet(report: item.report, library: library)
                    .motionFollowsAccessibility()
            }
            .sheet(item: $model.duplicatesSheet) { item in
                DuplicatesSheet(exact: item.exact, near: item.near, library: library)
                    .motionFollowsAccessibility()
            }
    }
}

/// What Verify Files found: damaged files first, by name and folder, with
/// a way to select them; then files changed since the last scan, missing
/// or unreadable.
struct FileVerificationSheet: View {
    let report: FileVerificationReport
    let library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let damaged = report.with(.damaged)
        let changed = report.with(.changed)
        let missing = report.with(.missing)
        let unreadable = report.with(.unreadable)
        VStack(alignment: .leading, spacing: 12) {
            Text("Verify Files").font(.headline)
            Text(report.summary).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if damaged.isEmpty && changed.isEmpty && missing.isEmpty && unreadable.isEmpty {
                Label("Every file matches the content recorded for it.", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            } else {
                List {
                    if !damaged.isEmpty {
                        Section {
                            ForEach(damaged, id: \.imageID) { row($0) }
                        } header: {
                            Text("Damaged: same size and date, different content")
                        } footer: {
                            Text("Nothing changes a file this way on purpose. Restore these from a backup.")
                        }
                    }
                    if !changed.isEmpty {
                        Section("Changed since the last scan (Refresh Folder records them)") {
                            ForEach(changed, id: \.imageID) { row($0) }
                        }
                    }
                    if !missing.isEmpty {
                        Section("Missing") { ForEach(missing, id: \.imageID) { row($0) } }
                    }
                    if !unreadable.isEmpty {
                        Section("Couldn’t be read") { ForEach(unreadable, id: \.imageID) { row($0) } }
                    }
                }
                .frame(minHeight: 220)
            }
            HStack {
                if !damaged.isEmpty {
                    Button("Select Damaged Photos") {
                        let ids = damaged.map(\.imageID)
                        library.setSelection(Set(ids), primary: ids.first)
                        dismiss()
                    }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func row(_ check: FileIntegrity.Check) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(check.fileName)
            let folder = (check.relPath as NSString).deletingLastPathComponent
            if !folder.isEmpty || check.detail != nil {
                Text([folder, check.detail ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Find Duplicates: groups of identical files, then photos taken at the
/// same moment with the same camera and size. The first of each group is
/// the one to keep (edited, then the higher rating, then the first path);
/// Select All but First and Reject All but First act on the rest.
/// Latent never deletes a file, so rejecting them is as far as it goes.
struct DuplicatesSheet: View {
    let exact: [DuplicateFinder.Group]
    let near: [DuplicateFinder.Group]
    let library: Library
    @State private var includesNear = false
    @Environment(\.dismiss) private var dismiss

    private var groups: [DuplicateFinder.Group] { exact + (includesNear ? near : []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Duplicates").font(.headline)
            Text(Self.summary(exact: exact.count, near: near.count)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if exact.isEmpty && near.isEmpty {
                Label("No two photos in this folder share their content.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                List {
                    if !exact.isEmpty {
                        Section("Identical files") {
                            ForEach(exact) { group($0) }
                        }
                    }
                    if !near.isEmpty {
                        Section("Same moment, camera and size, different files") {
                            ForEach(near) { group($0) }
                        }
                    }
                }
                .frame(minHeight: 260)
                if !near.isEmpty {
                    Toggle("Include same-moment photos in the actions below", isOn: $includesNear)
                }
            }
            HStack {
                Button("Select All but First") {
                    select(DuplicateFinder.allButFirst(groups))
                    dismiss()
                }
                .disabled(groups.isEmpty)
                Button("Reject All but First") {
                    let ids = DuplicateFinder.allButFirst(groups)
                    select(ids)
                    let library = library
                    library.perform("Reject Duplicates") { try await library.setFlag(.rejected) }
                    dismiss()
                }
                .disabled(groups.isEmpty)
                .help("Flags every photo but the first of each group as rejected. Undo puts them back.")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    static func summary(exact: Int, near: Int) -> String {
        "\(exact) group\(exact == 1 ? "" : "s") of identical files"
            + (near > 0 ? " · \(near) group\(near == 1 ? "" : "s") taken at the same moment" : "")
    }

    private func select(_ ids: [Int64]) {
        library.setSelection(Set(ids), primary: ids.first)
    }

    private func group(_ group: DuplicateFinder.Group) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(group.records.enumerated()), id: \.offset) { index, record in
                Button {
                    if let id = record.id { select([id]) }
                } label: {
                    HStack {
                        Text(record.relPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if index == 0 { Text("Keep").font(.caption).foregroundStyle(.secondary) }
                        Text(ByteCountFormatter.string(fromByteCount: record.size, countStyle: .file))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Selects this photo in the grid")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Grid badge

/// The grid's mark for a file Verify Files found damaged: a red warning
/// triangle in the picture's top-left corner.
final class DamagedFileBadgeView: NSView {
    static let side: CGFloat = 16
    static let inset: CGFloat = 3

    private let symbol = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.backgroundColor = NSColor(white: 0, alpha: 0.6).cgColor
        let configuration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        symbol.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        symbol.contentTintColor = .systemRed
        symbol.imageScaling = .scaleProportionallyDown
        addSubview(symbol)
        setAccessibilityElement(false)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        symbol.frame = bounds.insetBy(dx: 2, dy: 2)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Its frame in a flipped cell: the top-left corner of the picture.
    static func frame(inImageFrame image: CGRect) -> CGRect {
        CGRect(x: image.minX + inset, y: image.minY + inset, width: side, height: side)
    }
}
