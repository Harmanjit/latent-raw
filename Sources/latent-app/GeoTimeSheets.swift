import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Catalog

/// Metadata › Edit Capture Time… and Geotag from GPX Track…: the menu
/// commands, and the sheets that set them up. The work itself is in the
/// Catalog (Library+GeoTime.swift, GPXTrack.swift); nothing here touches a
/// raw file or the network.
enum MetadataCommand: Equatable, Sendable {
    case editCaptureTime, geotagFromGPX

    var title: String {
        switch self {
        case .editCaptureTime: "Edit Capture Time…"
        case .geotagFromGPX: "Geotag from GPX Track…"
        }
    }
}

extension CommandState {
    /// Both work on the selection (the visible selection, as a rating
    /// does), and wait while files move under the grid.
    func isEnabled(_ command: MetadataCommand) -> Bool {
        hasCatalog && (hasSelection || selectionCount > 0) && !fileOperationRunning && mode != .survey
    }
}

/// Holds the sheet on show, so ContentView needs one modifier and one
/// line in `perform(_:)`.
@MainActor
final class GeoTimePresenter: ObservableObject {
    static let shared = GeoTimePresenter()
    @Published var captureTimeSheet: CaptureTimeSheetModel?
    @Published var geotagSheet: GeotagSheetModel?

    func perform(_ command: MetadataCommand, library: Library) {
        let records = library.batchTargets(onlyPrimary: false)
        guard !records.isEmpty else { return }
        switch command {
        case .editCaptureTime:
            captureTimeSheet = CaptureTimeSheetModel(records: records)
        case .geotagFromGPX:
            chooseTrack(for: records, library: library)
        }
    }

    /// Asks for a .gpx file and reads it off the main actor. A file that
    /// isn't a usable track is reported in the status bar.
    private func chooseTrack(for records: [ImageRecord], library: Library) {
        let panel = NSOpenPanel()
        panel.title = "Geotag from GPX Track"
        panel.message = "Choose a GPX track recorded while the photos were taken."
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            let result = await Task.detached { () -> Result<GPXTrack, any Error> in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result { try GPXTrack.read(from: url) }
            }.value
            switch result {
            case .success(let track):
                geotagSheet = GeotagSheetModel(records: records, track: track, trackName: url.lastPathComponent)
            case .failure(let error):
                library.lastError = "Geotag from GPX Track failed: \(error)"
            }
        }
    }
}

extension View {
    /// The Edit Capture Time and Geotag sheets, for ContentView.
    func geoTimeSheets(library: Library) -> some View {
        modifier(GeoTimeSheetHost(library: library))
    }
}

private struct GeoTimeSheetHost: ViewModifier {
    @ObservedObject var presenter = GeoTimePresenter.shared
    let library: Library

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenter.captureTimeSheet) { sheet in
                CaptureTimeSheet(model: sheet, library: library).motionFollowsAccessibility()
            }
            .sheet(item: $presenter.geotagSheet) { sheet in
                GeotagSheet(model: sheet, library: library).motionFollowsAccessibility()
            }
    }
}

// MARK: - Edit Capture Time

/// The Edit Capture Time sheet's choices for the photos it was opened on.
@MainActor
final class CaptureTimeSheetModel: ObservableObject, Identifiable {
    enum Mode: Hashable { case shift, setFirst }

    let records: [ImageRecord]
    @Published var mode: Mode = .shift
    /// Shift: later (true) or earlier, and by how much.
    @Published var later = true
    @Published var days = 0
    @Published var hours = 0
    @Published var minutes = 0
    @Published var seconds = 0
    /// Set first photo to: the minute from the date picker, and its seconds.
    @Published var firstTime: Date
    @Published var firstSeconds: Int
    /// Time-zone shift (shift mode only).
    @Published var shiftsTimeZone = false
    @Published var fromZone = TimeZone.current.identifier
    @Published var toZone = TimeZone.current.identifier

    init(records: [ImageRecord]) {
        self.records = records
        let first = records.compactMap(\.captureTime).min().map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
        firstTime = first
        firstSeconds = Calendar.current.component(.second, from: first)
    }

    /// The photos that have a capture time to move.
    var datedCount: Int { records.filter { $0.captureTime != nil }.count }
    var earliest: Int64? { records.compactMap(\.captureTime).min() }

    var edit: CaptureTimeEdit {
        switch mode {
        case .shift:
            let magnitude = CaptureTimeEdit.seconds(days: days, hours: hours, minutes: minutes, seconds: seconds)
            var zoneShift: Int64 = 0
            if shiftsTimeZone, let from = TimeZone(identifier: fromZone), let to = TimeZone(identifier: toZone) {
                let at = earliest.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date()
                zoneShift = CaptureTimeEdit.timeZoneShift(from: from, to: to, at: at)
            }
            return CaptureTimeEdit(mode: .shift(seconds: later ? magnitude : -magnitude), timeZoneShift: zoneShift)
        case .setFirst:
            // The picker gives the minute; the seconds come from their field.
            let minute = Calendar.current.dateInterval(of: .minute, for: firstTime)?.start ?? firstTime
            let target = Int64(minute.timeIntervalSince1970) + Int64(firstSeconds)
            return CaptureTimeEdit(mode: .setFirst(to: target))
        }
    }

    /// How far every photo moves, nil when none has a capture time.
    var delta: Int64? { edit.delta(forCaptureTimes: records.compactMap(\.captureTime)) }

    /// "+1 d 2 h 3 min 4 s" for a shift in seconds.
    static func describe(_ delta: Int64) -> String {
        if delta == 0 { return "no change" }
        var rest = abs(delta)
        let d = rest / 86_400; rest %= 86_400
        let h = rest / 3_600; rest %= 3_600
        let m = rest / 60, s = rest % 60
        var parts: [String] = []
        if d > 0 { parts.append("\(d) d") }
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 { parts.append("\(s) s") }
        return (delta < 0 ? "−" : "+") + parts.joined(separator: " ")
    }

    /// Every time zone, by name, with its offset now: "Europe/London (UTC+01:00)".
    static let zones: [(id: String, label: String)] = TimeZone.knownTimeZoneIdentifiers.sorted().compactMap { id in
        guard let zone = TimeZone(identifier: id) else { return nil }
        let offset = zone.secondsFromGMT()
        let sign = offset < 0 ? "−" : "+"
        let hhmm = String(format: "%02d:%02d", abs(offset) / 3600, abs(offset) % 3600 / 60)
        return (id, "\(id) (UTC\(sign)\(hhmm))")
    }
}

struct CaptureTimeSheet: View {
    @ObservedObject var model: CaptureTimeSheetModel
    let library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Capture Time").font(.headline)
            Text("Moves the capture time of the \(model.records.count == 1 ? "selected photo" : "\(model.records.count) selected photos") by the same amount, keeping their order. The raw files aren’t changed: the corrected time is kept in the catalog and the sidecar, and can be undone.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Adjust:", selection: $model.mode) {
                Text("Shift by a set amount").tag(CaptureTimeSheetModel.Mode.shift)
                Text("Set the first photo to an exact time, and shift the rest by as much").tag(CaptureTimeSheetModel.Mode.setFirst)
            }
            .pickerStyle(.radioGroup)

            if model.mode == .shift {
                shiftControls
            } else {
                HStack {
                    Text("First photo:")
                    DatePicker("First photo", selection: $model.firstTime, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                    amountField("s", value: $model.firstSeconds, range: 0...59)
                }
            }

            preview

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Change") {
                    let edit = model.edit, records = model.records
                    library.perform("Edit Capture Time") {
                        try await library.editCaptureTime(edit, for: records)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((model.delta ?? 0) == 0)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var shiftControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Direction", selection: $model.later) {
                    Text("Later").tag(true)
                    Text("Earlier").tag(false)
                }
                .labelsHidden()
                .frame(width: 90)
                amountField("d", value: $model.days, range: 0...3650)
                amountField("h", value: $model.hours, range: 0...23)
                amountField("min", value: $model.minutes, range: 0...59)
                amountField("s", value: $model.seconds, range: 0...59)
            }
            Toggle("Also change time zone", isOn: $model.shiftsTimeZone)
                .help("For a camera left on home time: moves the clock times from one zone to the other")
            if model.shiftsTimeZone {
                Picker("Camera was set to:", selection: $model.fromZone) {
                    ForEach(CaptureTimeSheetModel.zones, id: \.id) { Text($0.label).tag($0.id) }
                }
                Picker("Photos were taken in:", selection: $model.toZone) {
                    ForEach(CaptureTimeSheetModel.zones, id: \.id) { Text($0.label).tag($0.id) }
                }
            }
        }
    }

    private func amountField(_ unit: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 2) {
            TextField(unit, value: value, format: .number)
                .frame(width: 44)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(unit)
                .onChange(of: value.wrappedValue) { _, new in
                    let clamped = min(max(new, range.lowerBound), range.upperBound)
                    if clamped != new { value.wrappedValue = clamped }
                }
            Stepper(unit, value: value, in: range).labelsHidden()
            Text(unit).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let earliest = model.earliest, let delta = model.delta {
                Text("First photo: \(MetadataFormat.captureTime(earliest)) → \(MetadataFormat.captureTime(earliest + delta))")
                Text("Every photo moves \(CaptureTimeSheetModel.describe(delta)).")
            } else {
                Text("None of the selected photos has a capture time to change.")
            }
            let undated = model.records.count - model.datedCount
            if undated > 0 {
                Text("\(undated) without a capture time will be left alone.")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Geotag from GPX Track

/// The Geotag sheet's choices: the track read, the photos it was opened
/// on, and how to match them.
@MainActor
final class GeotagSheetModel: ObservableObject, Identifiable {
    let records: [ImageRecord]
    let track: GPXTrack
    let trackName: String
    /// The camera clock's offset in whole minutes (the slider) and extra
    /// seconds (the stepper), added to each photo's time before matching.
    @Published var offsetMinutes: Double = 0
    @Published var offsetSeconds = 0
    @Published var maxGap: TimeInterval = 15 * 60
    @Published var replaceExisting = false

    static let gapChoices: [(seconds: TimeInterval, title: String)] = [
        (60, "1 minute"), (5 * 60, "5 minutes"), (15 * 60, "15 minutes"),
        (60 * 60, "1 hour"), (6 * 60 * 60, "6 hours"),
    ]

    init(records: [ImageRecord], track: GPXTrack, trackName: String) {
        self.records = records
        self.track = track
        self.trackName = trackName
    }

    var clockOffset: TimeInterval { offsetMinutes.rounded() * 60 + TimeInterval(offsetSeconds) }

    var plan: GeotagPlan {
        GeotagPlan.make(records: records, track: track, clockOffset: clockOffset,
                        maxGap: maxGap, replaceExisting: replaceExisting)
    }

    /// "+1 h 05 min 30 s" for the offset.
    var offsetDescription: String {
        let total = Int64(clockOffset.rounded())
        return total == 0 ? "none" : CaptureTimeSheetModel.describe(total)
    }
}

struct GeotagSheet: View {
    @ObservedObject var model: GeotagSheetModel
    let library: Library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let plan = model.plan
        VStack(alignment: .leading, spacing: 14) {
            Text("Geotag from GPX Track").font(.headline)
            trackSummary
            HStack {
                Text("Camera clock offset:")
                // Whole minutes, rounded here rather than with `step:`, which
                // would draw 1,441 tick marks as one black bar.
                Slider(value: Binding(get: { model.offsetMinutes }, set: { model.offsetMinutes = $0.rounded() }),
                       in: -720...720)
                    .accessibilityLabel("Camera clock offset in minutes")
                    .accessibilityValue(model.offsetDescription)
                Stepper("Seconds", value: $model.offsetSeconds, in: -59...59).labelsHidden()
                Text(model.offsetDescription).monospacedDigit().frame(width: 130, alignment: .trailing)
            }
            .help("Added to each photo’s capture time before it is matched: for a camera clock that was fast, slow, or set to another time zone")
            HStack {
                Button("Reset Offset") { model.offsetMinutes = 0; model.offsetSeconds = 0 }
                    .disabled(model.clockOffset == 0)
                Spacer()
            }
            Picker("Largest gap to bridge:", selection: $model.maxGap) {
                ForEach(GeotagSheetModel.gapChoices, id: \.seconds) { Text($0.title).tag($0.seconds) }
            }
            .help("A photo between two track points further apart than this, or this far beyond the track’s ends, isn’t placed")
            Toggle("Replace existing positions", isOn: $model.replaceExisting)
                .help("Off: photos that already have a position keep it")

            VStack(alignment: .leading, spacing: 4) {
                Text("\(plan.matchedCount) of \(model.records.count) photos will be geotagged.").bold()
                if plan.keptCount > 0 {
                    Text("\(plan.keptCount) already have a position and keep it.")
                }
                if plan.unmatchedCount > 0 {
                    Text("\(plan.unmatchedCount) fall outside the track or in a gap.")
                }
                if plan.noCaptureTimeCount > 0 {
                    Text("\(plan.noCaptureTimeCount) have no capture time.")
                }
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Geotag \(plan.matchedCount) Photo\(plan.matchedCount == 1 ? "" : "s")") {
                    let positions = plan.positionsToWrite, records = model.records
                    library.perform("Geotag from GPX Track") {
                        try await library.applyGeotags(positions, for: records)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(plan.matchedCount == 0)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var trackSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(model.trackName): \(model.track.points.count) timed points"
                 + (model.track.untimedPoints > 0 ? " (\(model.track.untimedPoints) without a time skipped)" : ""))
            if let range = model.track.timeRange {
                Text("From \(MetadataFormat.captureTime(Int64(range.lowerBound.timeIntervalSince1970))) to \(MetadataFormat.captureTime(Int64(range.upperBound.timeIntervalSince1970)))")
            }
            if let first = model.records.compactMap(\.captureTime).min(), let last = model.records.compactMap(\.captureTime).max() {
                Text("Photos from \(MetadataFormat.captureTime(first)) to \(MetadataFormat.captureTime(last))")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}
