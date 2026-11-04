import Combine
import SwiftUI
import Catalog

/// Settings › Performance: how thumbnails are made and kept. Lightroom's
/// Standard Preview quality, Preview Cache management and the like, as far
/// as they apply to Latent, which renders everything larger than a
/// thumbnail live (see Limitations).
@MainActor
final class PerformanceSettings: ObservableObject {
    static let shared = PerformanceSettings()

    /// How much memory decoded grid thumbnails may take.
    enum MemoryCache: String, CaseIterable, Identifiable {
        case automatic, small, medium, large, extraLarge

        var id: String { rawValue }
        var title: String {
            switch self {
            case .automatic: "Automatic (\(ByteCountFormatter.string(fromByteCount: Int64(ThumbnailLoader.defaultMemoryBytes), countStyle: .memory)))"
            case .small: "128 MB"
            case .medium: "256 MB"
            case .large: "512 MB"
            case .extraLarge: "1 GB"
            }
        }
        var bytes: Int {
            switch self {
            case .automatic: ThumbnailLoader.defaultMemoryBytes
            case .small: 128 << 20
            case .medium: 256 << 20
            case .large: 512 << 20
            case .extraLarge: 1 << 30
            }
        }
    }

    static let qualityKey = "latent.thumbnailQuality"
    static let priorityKey = "latent.thumbnailPriority"
    static let memoryKey = "latent.thumbnailMemoryCache"

    private let defaults: UserDefaults

    @Published var thumbnailQuality: ThumbnailGenerationSettings.Quality {
        didSet { defaults.set(thumbnailQuality.rawValue, forKey: Self.qualityKey) }
    }
    @Published var thumbnailPriority: ThumbnailGenerationSettings.Priority {
        didSet { defaults.set(thumbnailPriority.rawValue, forKey: Self.priorityKey) }
    }
    @Published var memoryCache: MemoryCache {
        didSet { defaults.set(memoryCache.rawValue, forKey: Self.memoryKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        thumbnailQuality = defaults.string(forKey: Self.qualityKey)
            .flatMap(ThumbnailGenerationSettings.Quality.init(rawValue:)) ?? .standard
        thumbnailPriority = defaults.string(forKey: Self.priorityKey)
            .flatMap(ThumbnailGenerationSettings.Priority.init(rawValue:)) ?? .normal
        memoryCache = defaults.string(forKey: Self.memoryKey).flatMap(MemoryCache.init(rawValue:)) ?? .automatic
    }

    var generation: ThumbnailGenerationSettings {
        ThumbnailGenerationSettings(quality: thumbnailQuality, priority: thumbnailPriority)
    }

    private var subscriptions: [AnyCancellable] = []

    /// Carries the settings into `library`, now and whenever they change.
    func apply(to library: Library) {
        library.thumbnailGeneration = generation
        library.thumbnailLoader.memoryBudget = memoryCache.bytes
        subscriptions = [
            Publishers.CombineLatest($thumbnailQuality, $thumbnailPriority)
                .map { ThumbnailGenerationSettings(quality: $0, priority: $1) }
                .removeDuplicates()
                .sink { [weak library] in library?.thumbnailGeneration = $0 },
            $memoryCache.removeDuplicates()
                .sink { [weak library] in library?.thumbnailLoader.memoryBudget = $0.bytes },
        ]
    }

    static func attached(to library: Library, settings: PerformanceSettings = .shared) -> Library {
        settings.apply(to: library)
        return library
    }
}

/// The Performance tab of Settings.
struct PerformanceSettingsTab: View {
    @ObservedObject private var settings = PerformanceSettings.shared
    @ObservedObject private var library = MainWindowModels.shared.library
    @State private var usage: ThumbnailCacheUsage?
    @State private var working = false
    @State private var confirmingDiscard = false
    @State private var message: String?

    var body: some View {
        Form {
            Section("Thumbnails") {
                Picker("Quality", selection: $settings.thumbnailQuality) {
                    ForEach(ThumbnailGenerationSettings.Quality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("How finely the 512 px thumbnails are compressed. High looks cleaner in large grid cells and takes more disk space. Applies to thumbnails made from now on; Rebuild Thumbnails (File menu) remakes the selected photos'.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Background generation", selection: $settings.thumbnailPriority) {
                    ForEach(ThumbnailGenerationSettings.Priority.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Low makes two at a time on the efficiency cores and leaves the Mac to you; High uses every core but two and fills a new folder fastest. Takes effect from the next pass.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Memory for the grid", selection: $settings.memoryCache) {
                    ForEach(PerformanceSettings.MemoryCache.allCases) { Text($0.title).tag($0) }
                }
                Text("Decoded thumbnails kept in memory so scrolling back needs no decoding. Half is given back when macOS runs short of memory, all of it when memory is critical.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Thumbnail cache") {
                if library.folderURL == nil {
                    Text("Open a folder to see its thumbnail cache.").foregroundStyle(.secondary)
                } else {
                    LabeledContent("This folder") {
                        Text(usageText).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    HStack {
                        Button("Remove Unused") { purge() }
                            .disabled(working || (usage?.orphanFiles ?? 0) == 0)
                            .help("Removes thumbnail files that no photo in this folder uses.")
                        Button("Discard and Rebuild All…") { confirmingDiscard = true }
                            .disabled(working)
                            .help("Throws away every thumbnail of this folder and makes them again at the current quality.")
                        if working { ProgressView().controlSize(.small) }
                        Spacer()
                    }
                    if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                }
                Text("Thumbnails live in the folder's _latent/thumbnails, excluded from Time Machine. They are only a cache: anything removed here is made again from the photos.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: library.folderURL) { await measure() }
        .confirmationDialog("Discard every thumbnail of this folder?", isPresented: $confirmingDiscard) {
            Button("Discard and Rebuild") { discardAll() }
        } message: {
            Text("They are made again straight away. The grid shows placeholders until each one is ready.")
        }
    }

    private var usageText: String {
        guard let usage else { return "Measuring…" }
        let size = ByteCountFormatter.string(fromByteCount: usage.bytes, countStyle: .file)
        var text = "\(usage.files) files, \(size)"
        if usage.orphanFiles > 0 {
            text += " (\(usage.orphanFiles) unused, \(ByteCountFormatter.string(fromByteCount: usage.orphanBytes, countStyle: .file)))"
        }
        return text
    }

    private func measure() async {
        usage = nil
        usage = try? await library.thumbnailCacheUsage()
    }

    private func purge() {
        working = true
        Task {
            defer { working = false }
            do {
                let freed = try await library.purgeOrphanThumbnails()
                message = "Freed \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file))."
            } catch {
                message = "Removing unused thumbnails failed: \(error)"
            }
            await measure()
        }
    }

    private func discardAll() {
        working = true
        Task {
            defer { working = false }
            do {
                try await library.discardAllThumbnails()
                message = "Thumbnails are being made again."
            } catch {
                message = "Discarding thumbnails failed: \(error)"
            }
            await measure()
        }
    }
}
