import SwiftUI
import PixelEngine

/// The viewing aids: focus peaking, raw clipping, colour assessment, the
/// clipping overlay's options and the high-quality preview, with what of
/// them persists. View settings only: nothing here is part of an edit.
///
/// The switches themselves (peaking, raw clipping, colour assessment) last
/// for the session, as Mirror Image Mode does, so the app never opens
/// looking different from how the user left their photos; their options
/// and the high-quality preview, which is a performance choice, persist.
@MainActor
final class ViewingSettings: ObservableObject {
    static let shared = ViewingSettings(defaults: .standard)

    /// The colours focus peaking can draw in (Settings › Viewing).
    enum PeakingColour: String, CaseIterable, Identifiable {
        case red, green, yellow, white
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        /// Linear Display P3.
        var linear: SIMD3<Float> {
            switch self {
            case .red: SIMD3(1, 0.05, 0.05)
            case .green: SIMD3(0.1, 1, 0.1)
            case .yellow: SIMD3(1, 0.9, 0)
            case .white: SIMD3(1, 1, 1)
            }
        }
    }

    private let defaults: UserDefaults

    // MARK: Switches (this session)

    /// View › Focus Peaking, in Develop, Loupe, Compare and Survey.
    @Published var focusPeaking = false
    /// View › Show Raw Clipping, in Develop.
    @Published var rawClipping = false
    /// View › Colour Assessment: the image inset over a mid-grey surround
    /// with a white frame.
    @Published var colourAssessment = false
    /// Help › Show Shortcuts Overlay.
    @Published var shortcutsOverlayShown = false
    /// The welcome sheet is up (first launch, or Help › Show Welcome).
    @Published var welcomeShown = false

    // MARK: Options (persisted)

    @Published var peakingColour: PeakingColour {
        didSet { defaults.set(peakingColour.rawValue, forKey: Keys.peakingColour) }
    }
    @Published var peakingSensitivity: PresentFocusPeaking.Sensitivity {
        didSet { defaults.set(peakingSensitivity.rawValue, forKey: Keys.peakingSensitivity) }
    }
    /// The share of the view's shorter side Colour Assessment leaves as
    /// grey border on every side, 5 to 20%.
    @Published var assessmentInset: Double {
        didSet {
            let clamped = Self.clampedInset(assessmentInset)
            if clamped != assessmentInset { assessmentInset = clamped; return }
            defaults.set(assessmentInset, forKey: Keys.assessmentInset)
        }
    }
    /// How the clipping overlay (J) marks the picture.
    @Published var clippingOptions: ClippingOptions {
        didSet {
            if clippingOptions == .standard {
                defaults.removeObject(forKey: Keys.clippingOptions)
            } else if let data = try? JSONEncoder().encode(clippingOptions) {
                defaults.set(data, forKey: Keys.clippingOptions)
            }
        }
    }
    /// View › High Quality Preview: off by default.
    @Published var highQualityPreview: Bool {
        didSet { defaults.set(highQualityPreview, forKey: Keys.highQualityPreview) }
    }

    enum Keys {
        static let peakingColour = "latent.viewing.peakingColour"
        static let peakingSensitivity = "latent.viewing.peakingSensitivity"
        static let assessmentInset = "latent.viewing.assessmentInset"
        static let clippingOptions = "latent.viewing.clippingOptions"
        static let highQualityPreview = "latent.viewing.highQualityPreview"
        static let welcomeSeen = "latent.welcomeSeen"
    }

    static let insetRange: ClosedRange<Double> = 0.05...0.20
    static let defaultInset = 0.10

    static func clampedInset(_ value: Double) -> Double {
        min(max(value, insetRange.lowerBound), insetRange.upperBound)
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        peakingColour = PeakingColour(rawValue: defaults.string(forKey: Keys.peakingColour) ?? "") ?? .red
        peakingSensitivity = PresentFocusPeaking.Sensitivity(rawValue: defaults.string(forKey: Keys.peakingSensitivity) ?? "") ?? .medium
        assessmentInset = Self.clampedInset(defaults.object(forKey: Keys.assessmentInset) as? Double ?? Self.defaultInset)
        clippingOptions = defaults.data(forKey: Keys.clippingOptions)
            .flatMap { try? JSONDecoder().decode(ClippingOptions.self, from: $0) } ?? .standard
        highQualityPreview = defaults.bool(forKey: Keys.highQualityPreview)
    }

    // MARK: What the presenter draws

    /// Focus peaking as the presenter takes it, or nil while it's off.
    var focusPeakingOverlay: PresentFocusPeaking? {
        focusPeaking ? PresentFocusPeaking(colour: peakingColour.linear, sensitivity: peakingSensitivity) : nil
    }

    /// The overlays for a viewport: peaking wherever an image is shown,
    /// the clipping options and raw clipping where the clipping overlay
    /// applies (`developTools`, Develop's own image).
    func overlays(developTools: Bool) -> PresentOverlays {
        PresentOverlays(focusPeaking: focusPeakingOverlay,
                        clipping: developTools ? clippingOptions : .standard,
                        rawClipping: developTools && rawClipping)
    }

    // MARK: The editor that pays for them

    /// The editor whose renders carry the raw clipping mask and the
    /// high-quality preview: the main window's (Develop and Loupe).
    /// Survey's panes and Develop's second pane are editors too; none of
    /// them shows either, so none pays for them.
    private(set) var primaryEditor: ObjectIdentifier?

    func setPrimaryEditor(_ model: EditorModel?) {
        primaryEditor = model.map(ObjectIdentifier.init)
    }

    func rendersRawClipping(for model: EditorModel) -> Bool {
        rawClipping && primaryEditor == ObjectIdentifier(model)
    }

    func rendersHighQualityPreview(for model: EditorModel) -> Bool {
        highQualityPreview && primaryEditor == ObjectIdentifier(model)
    }

    // MARK: Welcome

    /// Whether the welcome sheet has been seen on this Mac.
    var welcomeSeen: Bool {
        get { defaults.bool(forKey: Keys.welcomeSeen) }
        set { defaults.set(newValue, forKey: Keys.welcomeSeen) }
    }

    /// At launch: the welcome sheet the first time, except under tests or
    /// the snapshot harness, which must see the window as it is.
    func showWelcomeIfFirstRun(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !welcomeSeen, Self.allowsWelcome(environment: environment) else { return }
        welcomeShown = true
    }

    static func allowsWelcome(environment: [String: String]) -> Bool {
        environment["LATENT_SNAPSHOT_DIR"] == nil && environment["XCTestConfigurationFilePath"] == nil
            && environment["XCTestSessionIdentifier"] == nil
    }

    func dismissWelcome() {
        welcomeShown = false
        welcomeSeen = true
    }
}
