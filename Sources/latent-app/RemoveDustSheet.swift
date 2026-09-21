import SwiftUI
import UniformTypeIdentifiers
import Catalog
import PixelEngine
import RawCore

/// The Remove Dust options Latent remembers between runs, as it remembers
/// the merge dialogs' options: how the spots are found, the sensitivity,
/// the spot size and, for Use dust map, which map was used last.
///
/// A reference photo is never remembered: it belongs to one run.
struct DustRemovalPreferences {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let methodKey = "RemoveDust.method"
    static let sensitivityKey = "RemoveDust.sensitivity"
    static let sizeKey = "RemoveDust.size"
    static let mapIDKey = "RemoveDust.mapID"

    /// Find spots in each photo unless another way was chosen.
    var method: RemoveDustSheetModel.Method {
        get { defaults.string(forKey: Self.methodKey).flatMap(RemoveDustSheetModel.Method.init(rawValue:)) ?? .find }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.methodKey) }
    }

    /// 50 unless moved, clamped to the slider.
    var sensitivity: Int {
        get { defaults.object(forKey: Self.sensitivityKey) as? Int ?? 50 }
        nonmutating set { defaults.set(min(max(newValue, 0), 100), forKey: Self.sensitivityKey) }
    }

    var size: DustSpotSize {
        get { defaults.string(forKey: Self.sizeKey).flatMap(DustSpotSize.init(rawValue:)) ?? .medium }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.sizeKey) }
    }

    /// The map used last; nil until one was.
    var mapID: UUID? {
        get { defaults.string(forKey: Self.mapIDKey).flatMap(UUID.init(uuidString:)) }
        nonmutating set {
            if let newValue { defaults.set(newValue.uuidString, forKey: Self.mapIDKey) }
            else { defaults.removeObject(forKey: Self.mapIDKey) }
        }
    }

    var options: DustDetector.Options {
        DustDetector.Options(sensitivity: min(max(sensitivity, 0), 100), size: size)
    }
}

/// The Remove Dust dialog's state (Photo › Remove Dust…): which photos,
/// how the spots are found, and whether Remove Dust can go ahead. Kept
/// apart from the view so the tests can walk it through each choice.
///
/// **Options** start as they were last left (`DustRemovalPreferences`).
/// A remembered map that no longer exists falls back to the newest map
/// for the selection's camera, and with no map at all to Find spots.
///
/// **In memory** (Develop, the open image): Find spots and Use dust map
/// only; the editor does the work and Undo takes it back. The open image
/// may have been opened on its own, with no catalog row: then the dialog
/// knows it by what its file says (`init(openImage:camera:sensorSize:)`).
@MainActor
final class RemoveDustSheetModel: ObservableObject, Identifiable {
    enum Method: String, CaseIterable, Sendable {
        case find, map, reference
    }

    /// The reference photo a new map is made from.
    struct Reference: Equatable {
        let url: URL
        let name: String
        /// As the photo's file says; nil until read, or when it doesn't say.
        let camera: String?
        let sensorSize: SIMD2<Int>?
        /// Use the selected photo, rather than a file chosen in the panel.
        let isSelectedPhoto: Bool
    }

    /// What the dialog knows of a photo: enough to say which maps fit it
    /// and which photos a map or reference would skip.
    struct Photo: Equatable {
        let name: String
        let camera: String?
        let sensorSize: SIMD2<Int>?

        init(name: String, camera: String?, sensorSize: SIMD2<Int>?) {
            self.name = name
            self.camera = camera
            self.sensorSize = sensorSize
        }

        init(_ record: ImageRecord) {
            self.init(name: record.fileName, camera: record.camera,
                      sensorSize: record.width.flatMap { width in record.height.map { SIMD2(width, $0) } })
        }
    }

    /// The photos, in the grid's order; the first is the primary. Empty
    /// for an open image with no catalog row, which `photos` still lists.
    let records: [ImageRecord]
    /// The photos' files, one each, in the same order.
    let urls: [URL]
    let inMemory: Bool
    /// The photos as the dialog reasons about them, one per record, or
    /// the one open image.
    let photos: [Photo]
    /// The maps for the selection's cameras, newest first.
    let maps: [DustMap]

    @Published var method: Method {
        didSet {
            guard method != oldValue else { return }
            if method == .reference, inMemory { method = .find }
            if method == .map, selectedMapID == nil { selectedMapID = maps.first?.id }
        }
    }
    @Published var sensitivity: Int
    @Published var size: DustSpotSize
    /// The map Use dust map uses; nil when there is none to use.
    @Published var selectedMapID: UUID?
    @Published private(set) var reference: Reference?
    /// Why the chosen reference file can't be used, in words for the dialog.
    @Published private(set) var referenceProblem: String?
    @Published private(set) var isReadingReference = false

    let store: DustMapStore
    private let preferences: DustRemovalPreferences
    private var reading: Task<Void, Never>?

    /// `urls` are the files of `records`, in the same order.
    ///
    /// - Parameter defaults: where the options are remembered; tests pass
    ///   a suite of their own.
    convenience init(records: [ImageRecord], urls: [URL], inMemory: Bool = false, store: DustMapStore = DustMapStore(),
                     defaults: UserDefaults = .standard) {
        self.init(records: records, urls: urls, inMemory: inMemory, photos: records.map(Photo.init), store: store,
                  defaults: defaults)
    }

    /// The image open in Develop with no catalog row (File › Open), known
    /// by its file's name, camera and sensor size: Find spots and Use dust
    /// map, on the editor.
    convenience init(openImage name: String, camera: String?, sensorSize: SIMD2<Int>?,
                     store: DustMapStore = DustMapStore(), defaults: UserDefaults = .standard) {
        self.init(records: [], urls: [], inMemory: true,
                  photos: [Photo(name: name, camera: camera, sensorSize: sensorSize)], store: store, defaults: defaults)
    }

    private init(records: [ImageRecord], urls: [URL], inMemory: Bool, photos: [Photo], store: DustMapStore,
                 defaults: UserDefaults) {
        self.records = records
        self.urls = urls
        self.inMemory = inMemory
        self.photos = photos
        self.store = store
        let preferences = DustRemovalPreferences(defaults: defaults)
        self.preferences = preferences
        // Each camera's maps, newest first, in the order the cameras appear.
        var cameras: [String] = []
        for photo in photos {
            if let camera = photo.camera, !cameras.contains(camera) { cameras.append(camera) }
        }
        maps = cameras.flatMap { store.maps(forCamera: $0) }
        sensitivity = preferences.sensitivity
        size = preferences.size
        var method = preferences.method
        if method == .reference, inMemory { method = .find }
        var mapID = maps.first?.id
        if method == .map {
            if let remembered = preferences.mapID, maps.contains(where: { $0.id == remembered }) {
                mapID = remembered
            }
            if mapID == nil { method = .find }
        }
        selectedMapID = mapID
        self.method = method
    }

    // MARK: - What the dialog shows

    /// "Remove dust from 12 photos".
    var title: String {
        photos.count == 1 ? "Remove dust from 1 photo" : "Remove dust from \(photos.count) photos"
    }

    var selectedMap: DustMap? {
        maps.first { $0.id == selectedMapID }
    }

    /// Why Use dust map is disabled: "No dust map for Nikon D750 yet".
    var noMapText: String? {
        guard maps.isEmpty else { return nil }
        return "No dust map for \(photos.first?.camera ?? "this camera") yet"
    }

    /// The selected photo, for Use the selected photo.
    var selectedPhotoName: String? { photos.first?.name }

    var options: DustDetector.Options {
        DustDetector.Options(sensitivity: min(max(sensitivity, 0), 100), size: size)
    }

    /// The camera the photos must match under the current method, and its
    /// sensor size when known; nil when every photo is looked at on its own.
    private var targetCamera: (camera: String, sensorSize: SIMD2<Int>?)? {
        switch method {
        case .find: return nil
        case .map: return selectedMap.map { ($0.camera, $0.sensorSize) }
        case .reference: return reference?.camera.map { ($0, reference?.sensorSize) }
        }
    }

    /// How many of the photos the job would skip as being from another
    /// camera (or sensor size) than the map's or the reference's.
    var skippedCount: Int {
        guard let target = targetCamera else { return 0 }
        return photos.filter { photo in
            guard photo.camera == target.camera else { return true }
            guard let size = target.sensorSize, let own = photo.sensorSize else { return false }
            return own != size
        }.count
    }

    /// "3 of 12 photos are from another camera and will be skipped"; nil
    /// when every photo matches or the method looks at each on its own.
    var mismatchNote: String? {
        let skipped = skippedCount
        guard skipped > 0 else { return nil }
        if skipped == photos.count {
            return photos.count == 1
                ? "This photo is from another camera, so there is nothing to do"
                : "All \(photos.count) photos are from another camera, so there is nothing to do"
        }
        return "\(skipped) of \(photos.count) photo\(photos.count == 1 ? " is" : "s are") from another camera and will be skipped"
    }

    /// Whether Remove Dust has what it needs: a map to use, a reference
    /// that was read, and at least one photo the method applies to.
    var canRemove: Bool {
        switch method {
        case .find:
            return !photos.isEmpty
        case .map:
            return selectedMap != nil && skippedCount < photos.count
        case .reference:
            guard let reference, !isReadingReference else { return false }
            return reference.camera == nil || skippedCount < photos.count
        }
    }

    // MARK: - The reference photo

    /// Use the selected photo as the reference: what the catalog knows of
    /// it says which photos match.
    func useSelectedPhoto() {
        guard let record = records.first, let url = urls.first else { return }
        reading?.cancel()
        isReadingReference = false
        referenceProblem = nil
        let size = record.width.flatMap { width in record.height.map { SIMD2(width, $0) } }
        reference = Reference(url: url, name: record.fileName, camera: record.camera, sensorSize: size,
                              isSelectedPhoto: true)
        method = .reference
    }

    /// A file chosen in the open panel: its camera and sensor size are
    /// read off the file, off the main thread, since a raw's header
    /// takes a moment.
    func useReferenceFile(_ url: URL) {
        reading?.cancel()
        referenceProblem = nil
        isReadingReference = true
        reference = Reference(url: url, name: url.lastPathComponent, camera: nil, sensorSize: nil, isSelectedPhoto: false)
        method = .reference
        reading = Task { [weak self] in
            let outcome: Result<(String, SIMD2<Int>), any Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let summary = try RawFile(path: url.path, metadataOnly: true).summary
                    return .success((DustPhoto.camera(for: summary), SIMD2(summary.rawWidth, summary.rawHeight)))
                } catch {
                    return .failure(error)
                }
            }.value
            guard let self, !Task.isCancelled, self.reference?.url == url else { return }
            self.isReadingReference = false
            switch outcome {
            case .success((let camera, let size)):
                self.reference = Reference(url: url, name: url.lastPathComponent, camera: camera, sensorSize: size,
                                           isSelectedPhoto: false)
            case .failure(let error):
                self.reference = nil
                self.referenceProblem = "\(url.lastPathComponent) couldn’t be read: \(PhotoMergeQueue.describe(error))"
            }
        }
    }

    /// The panel's file dialog: raw formats mostly lack registered
    /// UTTypes, so it filters loosely and RawFile rejects the rest.
    func chooseReferenceFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a raw photo of a plain surface, such as the sky at f/16, that shows the sensor’s dust"
        panel.allowedContentTypes = [UTType.image]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        useReferenceFile(url)
    }

    // MARK: - Remove Dust

    /// The job Remove Dust starts, with the options remembered for next
    /// time; nil when the dialog isn't ready (`canRemove`).
    func job() -> DustRemovalJob? {
        guard canRemove else { return nil }
        remember()
        switch method {
        case .find:
            return DustRemovalJob(method: .find, options: options, store: store)
        case .map:
            guard let map = selectedMap else { return nil }
            return DustRemovalJob(method: .map(map), options: options, store: store)
        case .reference:
            guard let reference else { return nil }
            return DustRemovalJob(method: .reference(url: reference.url, name: reference.name), options: options,
                                  store: store)
        }
    }

    /// Writes the options back for the next dialog.
    func remember() {
        preferences.method = method
        preferences.sensitivity = sensitivity
        preferences.size = size
        if method == .map, let selectedMapID { preferences.mapID = selectedMapID }
    }

    func cancel() {
        reading?.cancel()
    }
}

/// Photo › Remove Dust…: how to find the spots, then Remove Dust runs the
/// job in the background (or, in Develop, on the open image in memory).
struct RemoveDustSheet: View {
    @ObservedObject var model: RemoveDustSheetModel
    /// Remove Dust was pressed; the dialog closes itself.
    let onRemove: (RemoveDustSheetModel) -> Void
    /// Remove Dust is refused while another GPU job (an export, a merge)
    /// runs.
    var canRemove = true
    @Environment(\.dismiss) private var dismiss

    static let width: CGFloat = 480
    private static let labelWidth: CGFloat = 90

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Picker("How to find the spots", selection: $model.method) {
                Text("Find spots in each photo").tag(RemoveDustSheetModel.Method.find)
                Text("Use dust map:").tag(RemoveDustSheetModel.Method.map)
                if !model.inMemory {
                    Text("New dust map from reference photo…").tag(RemoveDustSheetModel.Method.reference)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .accessibilityLabel("How to find the spots")

            mapRow
            if !model.inMemory { referenceRow }

            Divider()
            options

            if let note = model.mismatchNote {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text(model.inMemory
                     ? "The spots are healed on the open photo; Undo takes them back."
                     : "Each photo is analysed on this Mac; Undo in the Library takes the spots back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Cancel") { model.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove Dust") { onRemove(model); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRemove || !model.canRemove)
                    .help(canRemove ? "Find the spots and heal them"
                          : "Waits for the export or merge that is using the graphics processor")
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .onDisappear { model.cancel() }
    }

    /// The map popup under Use dust map, or why there is none.
    private var mapRow: some View {
        HStack(spacing: 8) {
            if let text = model.noMapText {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Dust map", selection: $model.selectedMapID) {
                    ForEach(model.maps) { map in
                        Text(map.title).tag(Optional(map.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                .accessibilityLabel("Dust map")
                .help("The saved dust map whose spots are looked for in each photo")
            }
            Spacer()
        }
        .padding(.leading, 20)
        .disabled(model.method != .map || model.maps.isEmpty)
    }

    /// Choose File… / Use the selected photo under New dust map.
    private var referenceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Choose File…") { model.chooseReferenceFile() }
                    .help("A raw photo of a plain surface, such as the sky at f/16, that shows the sensor’s dust")
                    .accessibilityLabel("Choose a reference photo")
                if let name = model.selectedPhotoName {
                    Button("Use the selected photo") { model.useSelectedPhoto() }
                        .help("Make the dust map from \(name)")
                        .accessibilityLabel("Use the selected photo, \(name), as the reference")
                }
                Spacer()
            }
            .controlSize(.small)
            if model.isReadingReference {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).accessibilityHidden(true)
                    Text("Reading \(model.reference?.name ?? "the photo")…")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else if let problem = model.referenceProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let reference = model.reference {
                Text(reference.camera.map { "\(reference.name) · \($0)" } ?? reference.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Reference photo \(reference.name)"
                                        + (reference.camera.map { ", \($0)" } ?? ""))
            } else {
                Text("The map is saved for the photo’s camera and used for every run after this one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, 20)
        .disabled(model.method != .reference)
    }

    /// Sensitivity and Spot Size, which every method uses.
    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Sensitivity")
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Slider(value: sensitivity, in: 0...100, step: 1)
                    .accessibilityLabel("Sensitivity")
                    .accessibilityValue("\(model.sensitivity)")
                    .help("Higher finds fainter and less round spots; lower keeps only the clearest")
                Text("\(model.sensitivity)")
                    .monospacedDigit()
                    .frame(width: 32, alignment: .trailing)
                    .accessibilityHidden(true)
            }
            HStack(spacing: 8) {
                Text("Spot Size")
                    .frame(width: Self.labelWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Picker("Spot size", selection: $model.size) {
                    ForEach(DustSpotSize.allCases, id: \.self) { band in
                        Text(band.displayName).tag(band)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                .accessibilityLabel("Spot size")
                .help("How big the shadows are: Small 4 to 8, Medium 6 to 16, Large 12 to 40 pixels across the sensor, halved")
                Spacer()
            }
        }
        .controlSize(.small)
    }

    private var sensitivity: Binding<Double> {
        Binding(get: { Double(model.sensitivity) }, set: { model.sensitivity = Int($0.rounded()) })
    }
}
