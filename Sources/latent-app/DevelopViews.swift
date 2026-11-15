import SwiftUI
import Combine
import Catalog
import PixelEngine
import UniformTypeIdentifiers

// MARK: - Layouts

/// Develop's Before/After views, as Lightroom's Y, ⌥Y and ⇧Y give them:
/// two panes side by side or one above the other, or one picture split
/// down the middle (or across), Before on the left or at the top.
enum BeforeAfterLayout: String, CaseIterable, Identifiable {
    case leftRight, leftRightSplit, topBottom, topBottomSplit

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftRight: "Left / Right"
        case .leftRightSplit: "Left / Right Split"
        case .topBottom: "Top / Bottom"
        case .topBottomSplit: "Top / Bottom Split"
        }
    }

    /// One picture, half of it Before and half After.
    var isSplit: Bool { self == .leftRightSplit || self == .topBottomSplit }
    /// Before above After rather than beside it.
    var isStacked: Bool { self == .topBottom || self == .topBottomSplit }

    /// The part of the viewport the After shows in a split: the right or
    /// the bottom half, as fractions of the view.
    var afterFraction: CGRect? {
        switch self {
        case .leftRightSplit: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topBottomSplit: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        default: nil
        }
    }

    /// The same with the line at `split` (0.05 to 0.95) of the view across
    /// or down, as the split line's drag leaves it; at 0.5 it is
    /// `afterFraction` exactly.
    func afterFraction(split: CGFloat) -> CGRect? {
        let s = BeforeAfterSplit.clamped(split)
        switch self {
        case .leftRightSplit: return CGRect(x: s, y: 0, width: 1 - s, height: 1)
        case .topBottomSplit: return CGRect(x: 0, y: s, width: 1, height: 1 - s)
        default: return nil
        }
    }
}

/// Where a split Before/After view divides: a fraction of the view across
/// (Left / Right Split) or down (Top / Bottom Split), dragged with the
/// line, the middle by default and again on a double-click.
enum BeforeAfterSplit {
    static let centre: CGFloat = 0.5
    static let range: ClosedRange<CGFloat> = 0.05...0.95

    static func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return centre }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// The fraction for a drag at `location` in a view of `size`.
    static func fraction(at location: CGPoint, in size: CGSize, stacked: Bool) -> CGFloat {
        let length = stacked ? size.height : size.width
        guard length > 0 else { return centre }
        return clamped((stacked ? location.y : location.x) / length)
    }
}

/// Reference view: the reference beside the active photo, or above it.
enum ReferenceLayout: String, CaseIterable, Identifiable {
    case leftRight, topBottom
    var id: String { rawValue }
    var title: String { self == .leftRight ? "Left / Right" : "Top / Bottom" }
}

/// What Develop's image area shows.
enum DevelopViewKind: Equatable {
    case single, beforeAfter, reference
}

/// ⇧Y: one image, then each Before/After layout in turn, then one image again.
func nextBeforeAfterStep(kind: DevelopViewKind, layout: BeforeAfterLayout) -> BeforeAfterLayout? {
    guard kind == .beforeAfter else { return .leftRight }
    let all = BeforeAfterLayout.allCases
    let index = all.firstIndex(of: layout)! + 1
    return index < all.count ? all[index] : nil
}

// MARK: - Commands

/// View › Loupe Overlay, and Develop's Before/After and Reference views,
/// under one `KeyCommand` case so the tables they pass through each gain
/// one line (as `GeometryCommand` does).
enum ViewCommand: Equatable {
    /// ⌥⌘O, and the three overlays it shows.
    case toggleOverlay, toggleOverlayGrid, toggleOverlayGuides, toggleOverlayLayout
    case chooseLayoutImage, resetGuides
    /// A Before/After layout, or nil for one image again.
    case beforeAfter(BeforeAfterLayout?)
    /// ⇧Y.
    case cycleBeforeAfter
    case copyAfterToBefore, copyBeforeToAfter, swapBeforeAfter, resetBefore
    /// ⇧R, and its layout.
    case referenceView, referenceLayout(ReferenceLayout)
    /// The photo being edited becomes the reference.
    case setReference
    case lockReference
    /// The reference becomes the photo being edited, and that the reference.
    case swapReference
    /// View › Show Navigator: Develop's panel section, and the floating
    /// card in Loupe, Compare and Survey (`NavigatorSettings`).
    case toggleNavigator
}

/// What the menus need of the view state.
struct ViewCommandState: Equatable {
    var overlayShown = false
    var navigatorShown = false
    var overlayGrid = false
    var overlayGuides = false
    var overlayLayout = false
    var developView: DevelopViewKind = .single
    var beforeAfterLayout: BeforeAfterLayout = .leftRight
    var referenceLayout: ReferenceLayout = .leftRight
    var hasReference = false
    var referenceLocked = false
    var hasCustomBefore = false
}

extension CommandState {
    func isEnabled(_ command: ViewCommand) -> Bool {
        let imageMode = (mode == .loupe || mode == .develop) && hasImage
        let developing = mode == .develop && hasImage
        switch command {
        case .toggleOverlay, .toggleOverlayGrid, .toggleOverlayGuides, .toggleOverlayLayout: return imageMode
        case .chooseLayoutImage: return true
        case .resetGuides: return views.overlayGuides
        case .beforeAfter, .cycleBeforeAfter, .copyAfterToBefore, .copyBeforeToAfter, .swapBeforeAfter: return developing
        case .resetBefore: return developing && views.hasCustomBefore
        case .referenceView, .referenceLayout: return developing
        case .setReference: return developing && hasSelection
        case .lockReference: return mode == .develop
        case .swapReference: return developing && views.developView == .reference && views.hasReference && hasSelection
        case .toggleNavigator: return mode.showsImage
        }
    }
}

// MARK: - State

/// Develop's second pane and what it shows: the Before of the photo being
/// edited, or a reference photo. One view-only `EditorModel` serves both
/// (they never show at once), created the first time either is asked for.
/// It is given no catalog id, so it never writes an edit.
///
/// The Before pane draws the Before with the After's crop and transform,
/// so the two line up in every layout, and follows the crop as it changes.
/// Its zoom and pan are linked to the editor's. The reference pane keeps
/// its own: it is usually another shape, and is there to be looked at.
///
/// Locked, the reference stays when Reference view closes, and across
/// launches while the same folder is open; unlocked, it goes when Reference
/// view closes, as in Lightroom.
@MainActor
final class DevelopViewState: ObservableObject {
    static let shared = DevelopViewState()

    @Published private(set) var kind: DevelopViewKind = .single
    @Published var beforeAfterLayout: BeforeAfterLayout {
        didSet { defaults.set(beforeAfterLayout.rawValue, forKey: Key.beforeAfterLayout) }
    }
    @Published var referenceLayout: ReferenceLayout {
        didSet { defaults.set(referenceLayout.rawValue, forKey: Key.referenceLayout) }
    }
    /// Where the split layouts divide (BeforeAfterSplit), for the session.
    @Published var splitFraction: CGFloat = BeforeAfterSplit.centre {
        didSet {
            let clamped = BeforeAfterSplit.clamped(splitFraction)
            if clamped != splitFraction { splitFraction = clamped }
        }
    }
    @Published private(set) var reference: ImageRecord?
    @Published var referenceLocked: Bool {
        didSet {
            defaults.set(referenceLocked, forKey: Key.locked)
            rememberReference()
        }
    }
    @Published private(set) var pane: EditorModel?
    /// The reference's histogram and vectorscope, for Scope menu › Overlay
    /// Reference (ReferenceScopes.swift); nil until measured, and again
    /// when the reference changes or goes.
    @Published private(set) var referenceScopes: ReferenceScopes?

    private let defaults: UserDefaults
    private weak var main: EditorModel?
    private weak var library: Library?
    /// The folder the reference belongs to: its id means nothing in another.
    private var referenceFolder: URL?
    private var observations: [AnyCancellable] = []
    private var paneProblems: AnyCancellable?
    private var paneRenders: AnyCancellable?
    private var overlayForwarding: AnyCancellable?
    private var navigatorForwarding: AnyCancellable?
    /// Develop's image area is on screen.
    private(set) var isShowing = false
    /// What the pane holds: the Before of this file, or this reference.
    private var loadedBefore: URL?
    private var loadedReferenceID: Int64?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        beforeAfterLayout = defaults.string(forKey: Key.beforeAfterLayout).flatMap(BeforeAfterLayout.init) ?? .leftRight
        referenceLayout = defaults.string(forKey: Key.referenceLayout).flatMap(ReferenceLayout.init) ?? .leftRight
        referenceLocked = defaults.bool(forKey: Key.locked)
        // The menus' ticks for the overlay come with this state's.
        overlayForwarding = LoupeOverlaySettings.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // And View › Show Navigator's.
        navigatorForwarding = NavigatorSettings.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// Ties the state to the editor and the library; once is enough.
    func attach(main: EditorModel, library: Library) {
        guard self.main !== main || self.library !== library else { return }
        self.main = main
        self.library = library
        // Published before the change lands: act once it has.
        observations = [
            main.$parameters.map { _ in () }.merge(with: main.$beforeOverride.map { _ in () },
                                                   main.$userRotation.map { _ in () })
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.syncBefore() },
            // Another image opened in the editor.
            main.$imageTitle.dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.update() },
            library.$folderURL.dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.folderChanged() },
        ]
    }

    // MARK: Showing

    func show() {
        isShowing = true
        update()
    }

    func hide() {
        isShowing = false
        if kind == .reference, !referenceLocked { clearReference() }
        update()
    }

    func setKind(_ next: DevelopViewKind) {
        guard next != kind else { return }
        if kind == .reference, !referenceLocked { clearReference() }
        kind = next
        if next == .reference, reference == nil { pickReference() }
        update()
    }

    /// The pane linked to the editor's view, for ContentView, which links
    /// Compare's panes in the same place.
    func linkedPane(for mode: AppMode) -> EditorModel? {
        mode == .develop && kind == .beforeAfter ? pane : nil
    }

    /// Links, loads or lets go of the pane for what now shows.
    private func update() {
        guard let main else { return }
        let showsPane = isShowing && kind != .single
        pane?.isOffScreen = !showsPane
        if let pane {
            if isShowing && kind == .beforeAfter {
                main.linkedPane = pane
                pane.linkedPane = main
            } else {
                if main.linkedPane === pane { main.linkedPane = nil }
                pane.linkedPane = nil
            }
        }
        guard showsPane else {
            if let pane, pane.hasImage, !MemoryPolicy.current.keepsIdleImages {
                pane.closeImage()
                loadedBefore = nil
                loadedReferenceID = nil
            }
            return
        }
        switch kind {
        case .single: break
        case .beforeAfter: loadBefore()
        case .reference: if let reference { loadReference(reference) }
        }
    }

    private func makePane() -> EditorModel {
        if let pane { return pane }
        let made = EditorModel()
        made.measuresScopes = false
        paneProblems = made.paneProblems.sink { [weak self] problem in
            MainActor.assumeIsolated { self?.main?.lastError = problem }
        }
        // Published as the render starts; measured once it has finished.
        paneRenders = made.$preview.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshReferenceScopes()
        }
        pane = made
        return made
    }

    // MARK: Before

    /// The Before, with the After's crop and transform so the panes line up.
    func composedBefore() -> EditParameters? {
        guard let main, main.hasImage else { return nil }
        var before = main.beforeParameters
        before.crop = main.parameters.crop
        before.perspective = main.parameters.perspective
        return before
    }

    private func loadBefore() {
        guard let main, let url = main.sourceURL, let before = composedBefore() else { return }
        let pane = makePane()
        if loadedBefore == url, pane.hasImage {
            syncBefore()
            return
        }
        loadedBefore = url
        loadedReferenceID = nil
        let json = try? EditStack(parameters: before).encodeJSON()
        pane.open(url: url, userRotation: main.userRotation, catalogImageID: nil, editStackJSON: json)
        pane.linkedPane = main
        main.linkedPane = pane
    }

    /// The Before pane follows the crop, the rotation and Copy After to Before.
    private func syncBefore() {
        guard isShowing, kind == .beforeAfter, let main, let pane, pane.hasImage,
              loadedBefore != nil, loadedBefore == main.sourceURL, let before = composedBefore() else { return }
        if pane.userRotation != main.userRotation { pane.setUserRotation(main.userRotation) }
        if pane.parameters != before { pane.parameters = before }
    }

    // MARK: Reference

    /// Entering Reference view with none: the locked one remembered for this
    /// folder, else another selected photo, else none until one is dropped.
    private func pickReference() {
        guard let library else { return }
        if referenceLocked, let folder = library.folderURL,
           defaults.string(forKey: Key.referenceFolder) == folder.path,
           let path = defaults.string(forKey: Key.referencePath),
           let record = library.visibleImages.first(where: { $0.relPath == path }) {
            setReference(record)
            return
        }
        if let other = library.selectedImages.first(where: { $0.id != library.selectedImageID }) {
            setReference(other)
        }
    }

    func setReference(_ record: ImageRecord) {
        if reference?.id != record.id { referenceScopes = nil }
        reference = record
        referenceFolder = library?.folderURL
        rememberReference()
        if kind != .reference { kind = .reference }
        update()
    }

    func clearReference() {
        reference = nil
        referenceScopes = nil
        referenceFolder = nil
        loadedReferenceID = nil
    }

    /// A drop on the reference pane: the filmstrip's image id, or a file
    /// the open folder holds.
    func setReference(imageID: Int64) {
        guard let record = library?.visibleImages.first(where: { $0.id == imageID }) else { return }
        setReference(record)
    }

    func setReference(fileURL: URL) {
        guard let library else { return }
        let wanted = fileURL.standardizedFileURL
        guard let record = library.visibleImages.first(where: { library.fileURL(for: $0)?.standardizedFileURL == wanted })
        else { NSSound.beep(); return }
        setReference(record)
    }

    private func rememberReference() {
        guard referenceLocked, let reference, let folder = referenceFolder else { return }
        defaults.set(reference.relPath, forKey: Key.referencePath)
        defaults.set(folder.path, forKey: Key.referenceFolder)
    }

    private func folderChanged() {
        guard reference != nil, referenceFolder != library?.folderURL else { return }
        clearReference()
        if kind == .reference, isShowing { pickReference() }
    }

    private func loadReference(_ record: ImageRecord) {
        guard let library, let id = record.id, loadedReferenceID != id || !(pane?.hasImage ?? false),
              referenceFolder == library.folderURL, let url = library.fileURL(for: record) else { return }
        let pane = makePane()
        loadedReferenceID = id
        loadedBefore = nil
        let catalog = library.catalog
        Task {
            // An edit just made to it, as the active photo, is saved first.
            await library.waitForPendingWork()
            do {
                let stack = try await library.editStack(for: record)
                guard library.catalog === catalog, self.loadedReferenceID == id, self.kind == .reference else { return }
                pane.open(url: url, userRotation: record.userRotation, catalogImageID: nil, editStackJSON: stack)
            } catch {
                self.main?.reportFailure("Reading the edit for \(record.fileName)", error)
            }
        }
    }

    /// Measures the reference's scopes from the pane while it shows the
    /// reference and Overlay Reference is on. Otherwise the last ones stay
    /// (a locked reference still overlays after Reference view closes).
    func refreshReferenceScopes() {
        guard ScopeSettings.shared.overlaysReference, reference != nil, kind == .reference,
              let id = reference?.id, loadedReferenceID == id, loadedBefore == nil,
              let pane, pane.hasImage, let measured = pane.measureReferenceScopes() else { return }
        referenceScopes = measured
    }

    // MARK: Commands

    /// Compare as Before in the History panel: the snapshot becomes the
    /// Before, and with one image showing, Left / Right Split shows it.
    /// A Before/After layout already showing stays.
    func compareSnapshot(_ snapshot: EditSnapshot) {
        guard let main, main.hasImage else { return }
        main.compareSnapshotAsBefore(snapshot)
        if kind != .beforeAfter {
            beforeAfterLayout = .leftRightSplit
            setKind(.beforeAfter)
        }
    }

    func perform(_ command: ViewCommand, load: (ImageRecord) -> Void) {
        let overlay = LoupeOverlaySettings.shared
        switch command {
        case .toggleOverlay:
            overlay.isShown.toggle()
            // Shown with nothing switched on, it shows the grid.
            if overlay.isShown, !overlay.hasAnythingToShow { overlay.showsGrid = true }
        case .toggleOverlayGrid:
            overlay.showsGrid.toggle()
            if overlay.showsGrid { overlay.isShown = true }
        case .toggleOverlayGuides:
            overlay.showsGuides.toggle()
            if overlay.showsGuides { overlay.isShown = true }
        case .toggleOverlayLayout:
            if overlay.layoutImage == nil { overlay.chooseLayoutImage(); break }
            overlay.showsLayoutImage.toggle()
            if overlay.showsLayoutImage { overlay.isShown = true }
        case .chooseLayoutImage:
            overlay.chooseLayoutImage()
        case .resetGuides:
            overlay.resetGuides()
        case .beforeAfter(let layout):
            if let layout {
                beforeAfterLayout = layout
                setKind(.beforeAfter)
            } else {
                setKind(.single)
            }
        case .cycleBeforeAfter:
            if let next = nextBeforeAfterStep(kind: kind, layout: beforeAfterLayout) {
                beforeAfterLayout = next
                setKind(.beforeAfter)
            } else {
                setKind(.single)
            }
        case .copyAfterToBefore:
            main?.copyAfterToBefore()
        case .copyBeforeToAfter:
            main?.copyBeforeToAfter()
        case .swapBeforeAfter:
            main?.swapBeforeAndAfter()
        case .resetBefore:
            main?.resetBefore()
        case .referenceView:
            setKind(kind == .reference ? .single : .reference)
        case .referenceLayout(let layout):
            referenceLayout = layout
            setKind(.reference)
        case .setReference:
            if let selected = library?.selectedImage { setReference(selected) }
        case .lockReference:
            referenceLocked.toggle()
        case .swapReference:
            guard let reference, let active = library?.selectedImage else { return }
            main?.flushPendingSave()
            setReference(active)
            load(reference)
        case .toggleNavigator:
            NavigatorSettings.shared.isShown.toggle()
        }
    }

    func commandState(main: EditorModel) -> ViewCommandState {
        let overlay = LoupeOverlaySettings.shared
        var state = ViewCommandState()
        state.overlayShown = overlay.isShown
        state.navigatorShown = NavigatorSettings.shared.isShown
        state.overlayGrid = overlay.showsGrid
        state.overlayGuides = overlay.showsGuides
        state.overlayLayout = overlay.showsLayoutImage && overlay.layoutImage != nil
        state.developView = kind
        state.beforeAfterLayout = beforeAfterLayout
        state.referenceLayout = referenceLayout
        state.hasReference = reference != nil
        state.referenceLocked = referenceLocked
        state.hasCustomBefore = main.hasCustomBefore
        return state
    }

    private enum Key {
        static let beforeAfterLayout = "latent.develop.beforeAfterLayout"
        static let referenceLayout = "latent.develop.referenceLayout"
        static let locked = "latent.develop.referenceLocked"
        static let referencePath = "latent.develop.referencePath"
        static let referenceFolder = "latent.develop.referenceFolder"
    }
}

// MARK: - Views

/// The pasteboard type the filmstrip's drags carry beside the file: the
/// image's catalog id, so a virtual copy drops as itself.
let imageIDPasteboardType = NSPasteboard.PasteboardType("com.latent.image-id")

/// Develop's image area: the editor's viewport alone, or with the Before
/// or a reference photo beside it.
struct DevelopImageArea: View {
    @ObservedObject var state: DevelopViewState
    @ObservedObject var model: EditorModel
    @ObservedObject var library: Library
    let onStep: (Int) -> Void
    let onSwapReference: () -> Void

    var body: some View {
        Group {
            switch state.kind {
            case .single:
                ImageViewport(model: model, onStep: onStep, showsLoupeOverlay: true)
            case .beforeAfter:
                VStack(spacing: 0) {
                    beforeAfter
                    Divider()
                    beforeAfterBar
                }
            case .reference:
                VStack(spacing: 0) {
                    referenceView
                    Divider()
                    referenceBar
                }
            }
        }
        .onAppear {
            state.attach(main: model, library: library)
            state.show()
        }
        .onDisappear { state.hide() }
    }

    // MARK: Before / After

    @ViewBuilder
    private var beforeAfter: some View {
        let layout = state.beforeAfterLayout
        if let fraction = layout.afterFraction(split: state.splitFraction) {
            ZStack {
                beforePane
                ImageViewport(model: model, mirror: state.pane, showsLoupeOverlay: true, visibleFraction: fraction)
                SplitLine(stacked: layout.isStacked, fraction: $state.splitFraction)
                PaneLabels(first: model.beforeLabel, second: "After", stacked: layout.isStacked,
                           fraction: state.splitFraction)
                    .allowsHitTesting(false)
            }
        } else {
            stack(stacked: layout.isStacked) {
                beforePane
                    .overlay(alignment: .topLeading) { PaneLabel(text: model.beforeLabel) }
                ImageViewport(model: model, mirror: state.pane, showsLoupeOverlay: true)
                    .overlay(alignment: .topLeading) { PaneLabel(text: "After") }
            }
        }
    }

    @ViewBuilder
    private var beforePane: some View {
        if let pane = state.pane {
            ImageViewport(model: pane, mirror: model, allowsTools: false)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Before pane")
        } else {
            AppPreferences.shared.surroundColor
        }
    }

    private var beforeAfterBar: some View {
        HStack(spacing: 10) {
            Picker("Layout", selection: Binding(get: { state.beforeAfterLayout },
                                                set: { state.perform(.beforeAfter($0), load: { _ in }) })) {
                ForEach(BeforeAfterLayout.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 210)
            .help("How the Before and After are laid out (⇧Y steps through them)")
            Button("Copy After → Before") { state.perform(.copyAfterToBefore, load: { _ in }) }
                .help("Make the current settings the Before")
            Button("Copy Before → After") { state.perform(.copyBeforeToAfter, load: { _ in }) }
                .help("Put the Before's settings on the photo (undoable)")
            Button("Swap") { state.perform(.swapBeforeAfter, load: { _ in }) }
                .help("Exchange the Before and After settings")
            if model.hasCustomBefore {
                Button(model.beforeSnapshotName == nil ? "Reset Before" : "Clear Before") {
                    state.perform(.resetBefore, load: { _ in })
                }
                .help("The Before goes back to the unedited photo")
            }
            Spacer()
            Button("Done") { state.perform(.beforeAfter(nil), load: { _ in }) }
                .help("Back to one image")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: Reference

    private var referenceView: some View {
        stack(stacked: state.referenceLayout == .topBottom) {
            referencePane
                .overlay(alignment: .topLeading) { PaneLabel(text: "Reference") }
            ImageViewport(model: model, onStep: onStep, showsLoupeOverlay: true)
                .overlay(alignment: .topLeading) { PaneLabel(text: "Active") }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Active pane")
        }
    }

    @State private var dropTargeted = false

    private var referencePane: some View {
        ZStack {
            if state.reference != nil, let pane = state.pane {
                ImageViewport(model: pane, mirror: model, allowsTools: false)
            } else {
                AppPreferences.shared.surroundColor
                Text("Drag a photo here from the filmstrip to make it the reference")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(24)
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 3).padding(2)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(state.reference.map { "Reference pane, \($0.fileName)" } ?? "Reference pane, empty")
        .onDrop(of: [UTType(importedAs: imageIDPasteboardType.rawValue), .fileURL], isTargeted: $dropTargeted) { providers in
            acceptDrop(providers)
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let idType = imageIDPasteboardType.rawValue
        if provider.hasItemConformingToTypeIdentifier(idType) {
            _ = provider.loadDataRepresentation(forTypeIdentifier: idType) { data, _ in
                guard let data, let text = String(data: data, encoding: .utf8), let id = Int64(text) else { return }
                Task { @MainActor in DevelopViewState.shared.setReference(imageID: id) }
            }
            return true
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in DevelopViewState.shared.setReference(fileURL: url) }
        }
        return true
    }

    private var referenceBar: some View {
        HStack(spacing: 10) {
            Picker("Layout", selection: Binding(get: { state.referenceLayout },
                                                set: { state.perform(.referenceLayout($0), load: { _ in }) })) {
                ForEach(ReferenceLayout.allCases) { Text($0.title).tag($0) }
            }
            .frame(width: 180)
            Toggle("Lock", isOn: $state.referenceLocked)
                .toggleStyle(.checkbox)
                .help("Keep the reference when Reference view closes, and next time")
                .accessibilityLabel("Lock reference photo")
            Button("Set Active as Reference") { state.perform(.setReference, load: { _ in }) }
                .disabled(library.selectedImage == nil)
            Button("Swap") { onSwapReference() }
                .disabled(state.reference == nil || library.selectedImage == nil)
                .help("Edit the reference: it becomes the active photo, and the active photo the reference")
            if let reference = state.reference {
                Text(reference.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Done") { state.perform(.referenceView, load: { _ in }) }
                .help("Back to one image (⇧R)")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: Parts

    @ViewBuilder
    private func stack<Content: View>(stacked: Bool, @ViewBuilder content: () -> Content) -> some View {
        if stacked {
            VStack(spacing: 1) { content() }
        } else {
            HStack(spacing: 1) { content() }
        }
    }
}

/// The name of a pane, in its top left corner.
private struct PaneLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .fontWeight(.semibold)
            .textCase(.uppercase)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .padding(8)
            .accessibilityHidden(true)
    }
}

/// A split view's two labels, each in its own part.
private struct PaneLabels: View {
    let first: String
    let second: String
    let stacked: Bool
    var fraction: CGFloat = BeforeAfterSplit.centre
    var body: some View {
        GeometryReader { geo in
            PaneLabel(text: first)
                .fixedSize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            PaneLabel(text: second)
                .fixedSize()
                .offset(x: stacked ? 0 : geo.size.width * fraction, y: stacked ? geo.size.height * fraction : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The line between a split view's parts. It takes the pointer only in a
/// narrow band along itself, so the image keeps every other click: drag it
/// to move the split (with the resize pointer over it), double-click it to
/// put it back in the middle.
private struct SplitLine: View {
    let stacked: Bool
    @Binding var fraction: CGFloat
    /// How wide the band that takes the pointer is, in points.
    private static let grab: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            let at = (stacked ? geo.size.height : geo.size.width) * fraction
            Path { path in
                if stacked {
                    path.move(to: CGPoint(x: 0, y: at))
                    path.addLine(to: CGPoint(x: geo.size.width, y: at))
                } else {
                    path.move(to: CGPoint(x: at, y: 0))
                    path.addLine(to: CGPoint(x: at, y: geo.size.height))
                }
            }
            .stroke(Color.white.opacity(0.85), lineWidth: 1)
            .allowsHitTesting(false)
            Color.clear
                .frame(width: stacked ? geo.size.width : Self.grab, height: stacked ? Self.grab : geo.size.height)
                .contentShape(Rectangle())
                .position(x: stacked ? geo.size.width / 2 : at, y: stacked ? at : geo.size.height / 2)
                .onHover { inside in
                    if inside {
                        (stacked ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .onTapGesture(count: 2) { fraction = BeforeAfterSplit.centre }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                    .onChanged { drag in
                        fraction = BeforeAfterSplit.fraction(at: drag.location, in: geo.size, stacked: stacked)
                    })
                .accessibilityElement()
                .accessibilityLabel("Split line")
                .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: fraction = BeforeAfterSplit.clamped(fraction + 0.05)
                    case .decrement: fraction = BeforeAfterSplit.clamped(fraction - 0.05)
                    @unknown default: break
                    }
                }
        }
        .coordinateSpace(name: Self.space)
    }

    private static let space = "before-after-split"
}

// MARK: - Menus

/// View › Loupe Overlay, and View › Before/After and Reference View.
struct ViewModesMenus: View {
    let state: ViewCommandState
    let item: (String, KeyCommand) -> AnyView
    let toggle: (String, KeyCommand, Bool) -> AnyView

    var body: some View {
        toggle("Show Navigator", .view(.toggleNavigator), state.navigatorShown)
        Menu("Loupe Overlay") {
            toggle("Show Overlay", .view(.toggleOverlay), state.overlayShown)
            Divider()
            toggle("Grid", .view(.toggleOverlayGrid), state.overlayGrid)
            toggle("Guides", .view(.toggleOverlayGuides), state.overlayGuides)
            toggle("Layout Image", .view(.toggleOverlayLayout), state.overlayLayout)
            Divider()
            item("Choose Layout Image…", .view(.chooseLayoutImage))
            item("Reset Guides", .view(.resetGuides))
        }
        Menu("Before/After") {
            toggle("One Image", .view(.beforeAfter(nil)), state.developView == .single)
            ForEach(BeforeAfterLayout.allCases) { layout in
                toggle(layout.title, .view(.beforeAfter(layout)),
                       state.developView == .beforeAfter && state.beforeAfterLayout == layout)
            }
            item("Cycle Before/After Views", .view(.cycleBeforeAfter))
            Divider()
            item("Copy After’s Settings to Before", .view(.copyAfterToBefore))
            item("Copy Before’s Settings to After", .view(.copyBeforeToAfter))
            item("Swap Before and After Settings", .view(.swapBeforeAfter))
            item("Reset Before to Unedited", .view(.resetBefore))
        }
        Menu("Reference View") {
            toggle("Reference View", .view(.referenceView), state.developView == .reference)
            ForEach(ReferenceLayout.allCases) { layout in
                toggle(layout.title, .view(.referenceLayout(layout)),
                       state.developView == .reference && state.referenceLayout == layout)
            }
            Divider()
            item("Set as Reference Photo", .view(.setReference))
            toggle("Lock Reference Photo", .view(.lockReference), state.referenceLocked)
            item("Swap Reference and Active", .view(.swapReference))
        }
    }
}

// MARK: - Filmstrip drags

extension FilmstripView.Coordinator {
    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool {
        !indexPaths.isEmpty
    }

    /// The file, for Finder and other apps, and the image's id, for the
    /// reference pane.
    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard images.indices.contains(indexPath.item) else { return nil }
        let record = images[indexPath.item]
        let item = NSPasteboardItem()
        if let url = library.fileURL(for: record) { item.setString(url.absoluteString, forType: .fileURL) }
        if let id = record.id { item.setString(String(id), forType: imageIDPasteboardType) }
        return item
    }
}
