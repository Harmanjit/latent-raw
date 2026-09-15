import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Catalog
import PixelEngine

/// Settings > Slideshow, ported from minivu's.
///
/// One `Codable` value rather than a key per setting, so a show reads a
/// consistent set at once. Decoding fills a missing or unreadable field
/// with its default and clamps numbers into range, so settings saved by
/// another version, or edited with `defaults write`, always load.
struct SlideshowSettings: Codable, Equatable, Sendable {
    enum Caption: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, name, nameAndDate, exposure
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .name: "File name"
            case .nameAndDate: "File name and date"
            case .exposure: "Camera and exposure"
            }
        }
    }

    /// A song the user chose, kept as a security-scoped bookmark: under the
    /// sandbox a remembered path couldn't be opened next time. The name is
    /// kept so Settings can list it without resolving the bookmark.
    struct Song: Codable, Equatable, Hashable, Identifiable, Sendable {
        var id = UUID()
        var name: String
        var bookmark: Data
    }

    static let intervalRange: ClosedRange<Double> = 1...60
    static let transitionDurationRange: ClosedRange<Double> = 0.3...3

    /// Seconds each slide stays up once its transition has finished.
    var interval: Double = 5
    var transition: SlideshowTransition = .crossFade
    /// Seconds a transition takes; the arrow keys use a quicker one.
    var transitionDuration: Double = 1
    /// Start again after the last slide; otherwise the show ends there.
    var loop = true
    var caption: Caption = .none
    var playsMusic = false
    var songs: [Song] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case interval, transition, transitionDuration, loop, caption, playsMusic, songs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SlideshowSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            // One unreadable value (a transition from a later version) mustn't lose the rest.
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        interval = value(.interval, defaults.interval)
        transition = value(.transition, defaults.transition)
        transitionDuration = value(.transitionDuration, defaults.transitionDuration)
        loop = value(.loop, defaults.loop)
        caption = value(.caption, defaults.caption)
        playsMusic = value(.playsMusic, defaults.playsMusic)
        songs = value(.songs, defaults.songs)
        self = clamped()
    }

    /// Numbers pulled into their ranges (a NaN becomes the default).
    func clamped() -> SlideshowSettings {
        func clamp(_ value: Double, _ range: ClosedRange<Double>, _ fallback: Double) -> Double {
            value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : fallback
        }
        var copy = self
        copy.interval = clamp(interval, Self.intervalRange, 5)
        copy.transitionDuration = clamp(transitionDuration, Self.transitionDurationRange, 1)
        return copy
    }

    /// Whether there is music to play.
    var hasMusic: Bool { playsMusic && !songs.isEmpty }
}

/// Where slideshow settings live: one key in a defaults store of the
/// caller's choosing, so tests pass a scratch suite.
@MainActor
final class SlideshowSettingsStore: ObservableObject {
    static let shared = SlideshowSettingsStore(defaults: .standard)
    nonisolated static let key = "latent.slideshow"

    private let defaults: UserDefaults

    @Published var settings: SlideshowSettings {
        didSet {
            // Assigning inside didSet doesn't call it again.
            let clamped = settings.clamped()
            if clamped != settings { settings = clamped }
            if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
        }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        settings = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(SlideshowSettings.self, from: $0) } ?? SlideshowSettings()
    }
}

/// Which images a show plays and where it starts: the selection when more
/// than one image is selected, otherwise everything the filter shows, from
/// the selected image. Always in the grid's order.
enum SlideshowImages {
    static func choose(visible: [ImageRecord], selectedIDs: Set<Int64>,
                       primary: Int64?) -> (records: [ImageRecord], start: Int) {
        let records = selectedIDs.count > 1
            ? visible.filter { $0.id.map(selectedIDs.contains) ?? false }
            : visible
        let start = primary.flatMap { id in records.firstIndex { $0.id == id } } ?? 0
        return (records, start)
    }
}

/// Which slide plays when. Plain values with no AppKit, so every rule is
/// unit tested:
///
/// - **The ends**: looping, the last slide is followed by the first and the
///   first preceded by the last; without, there is nothing further and the
///   show ends after the last slide has had its time.
/// - **Failures**: an image that won't render is marked and skipped from
///   then on, in both directions.
struct SlideshowSequence: Equatable {
    let count: Int
    var loops: Bool
    private(set) var failed: Set<Int> = []

    init(count: Int, loops: Bool) {
        self.count = count
        self.loops = loops
    }

    /// Whether any image may still play.
    var hasPlayable: Bool { failed.count < count }

    /// The first playable index from `start` on (wrapping when looping), or nil.
    func first(from start: Int) -> Int? {
        guard count > 0 else { return nil }
        let begin = min(max(start, 0), count - 1)
        if !failed.contains(begin) { return begin }
        return step(from: begin, by: 1)
    }

    /// The playable index `direction` (+1 or -1) steps from `position`,
    /// past failed images; nil at an end without looping, or when no other
    /// image can play. Never `position` itself: one image doesn't
    /// transition into itself.
    func step(from position: Int, by direction: Int) -> Int? {
        guard count > 0 else { return nil }
        var candidate = position
        for _ in 0..<count {
            candidate += direction
            if candidate >= count {
                guard loops else { return nil }
                candidate = 0
            } else if candidate < 0 {
                guard loops else { return nil }
                candidate = count - 1
            }
            if candidate == position { return nil }
            if !failed.contains(candidate) { return candidate }
        }
        return nil
    }

    mutating func markFailed(_ index: Int) {
        failed.insert(index)
    }
}

/// What a slide's caption says.
enum SlideshowCaptionText {
    static func text(_ style: SlideshowSettings.Caption, record: ImageRecord,
                     timeZone: TimeZone = .current) -> String? {
        switch style {
        case .none:
            return nil
        case .name:
            return record.fileName
        case .nameAndDate:
            guard let time = record.captureTime else { return record.fileName }
            return "\(record.fileName)  ·  \(MetadataFormat.captureTime(time, timeZone: timeZone))"
        case .exposure:
            let parts = [record.camera, record.lens, record.exposureLine].compactMap { $0 }.filter { !$0.isEmpty }
            // A file without camera data says more by its name than by nothing.
            return parts.isEmpty ? record.fileName : parts.joined(separator: "  ·  ")
        }
    }
}

// MARK: - Settings > Slideshow

struct SlideshowSettingsTab: View {
    @ObservedObject var store = SlideshowSettingsStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Form {
            LabeledContent("Each slide") {
                HStack {
                    Slider(value: rounded($store.settings.interval, to: 1), in: SlideshowSettings.intervalRange)
                        .accessibilityLabel("Seconds each slide shows")
                        .accessibilityValue(seconds(store.settings.interval))
                    Text(seconds(store.settings.interval))
                        .monospacedDigit()
                        .frame(minWidth: 48, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
            Picker("Transition", selection: $store.settings.transition) {
                ForEach(SlideshowTransition.allCases) { Text($0.title).tag($0) }
            }
            if reduceMotion, store.settings.transition.reducingMotion(true) != store.settings.transition {
                Text("Reduce Motion is on, so this plays as a cross-fade.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Transition length") {
                HStack {
                    Slider(value: rounded($store.settings.transitionDuration, to: 0.1),
                           in: SlideshowSettings.transitionDurationRange)
                        .accessibilityLabel("Transition length")
                        .accessibilityValue(seconds(store.settings.transitionDuration))
                    Text(seconds(store.settings.transitionDuration))
                        .monospacedDigit()
                        .frame(minWidth: 48, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
            .disabled(store.settings.transition == .cut)
            Toggle("Start again after the last slide", isOn: $store.settings.loop)
            Picker("Caption", selection: $store.settings.caption) {
                ForEach(SlideshowSettings.Caption.allCases) { Text($0.title).tag($0) }
            }
            Text("A slideshow plays the selected images, or every image the filter shows when one or none is selected. ← and → step, Space pauses, Esc ends it.")
                .font(.caption).foregroundStyle(.secondary)

            Section("Music") {
                Toggle("Play music during slideshows", isOn: $store.settings.playsMusic)
                if store.settings.songs.isEmpty {
                    Text("No songs added").foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(store.settings.songs) { song in
                            Text(song.name).lineLimit(1).truncationMode(.middle)
                        }
                        .onDelete { store.settings.songs.remove(atOffsets: $0) }
                    }
                    .frame(minHeight: 60, maxHeight: 120)
                    .accessibilityLabel("Songs")
                }
                HStack {
                    Button("Add Songs…") { addSongs() }
                    Button("Remove All") { store.settings.songs = [] }
                        .disabled(store.settings.songs.isEmpty)
                }
                Text("Songs play in this order and start again at the end. They pause with the show.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// A slider without tick marks (a step draws one per value) that
    /// still lands on whole steps.
    private func rounded(_ value: Binding<Double>, to step: Double) -> Binding<Double> {
        Binding(get: { value.wrappedValue },
                set: { value.wrappedValue = ($0 / step).rounded() * step })
    }

    private func seconds(_ value: Double) -> String {
        abs(value.rounded() - value) < 0.01 ? "\(Int(value.rounded())) s" : String(format: "%.1f s", value)
    }

    private func addSongs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose songs to play during slideshows"
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.compactMap { url -> SlideshowSettings.Song? in
            guard let bookmark = BookmarkStore.bookmark(for: url) else { return nil }
            return SlideshowSettings.Song(name: url.deletingPathExtension().lastPathComponent, bookmark: bookmark)
        }
        store.settings.songs += added
        if !added.isEmpty { store.settings.playsMusic = true }
    }
}
