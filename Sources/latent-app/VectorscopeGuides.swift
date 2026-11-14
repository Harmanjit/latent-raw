import SwiftUI
import PixelEngine

/// Colour-harmony guides drawn over the vectorscope: spokes at the hues
/// that go with a base hue, as darktable's vectorscope draws them.
enum HarmonyGuide: String, CaseIterable, Identifiable {
    case none, complementary, splitComplementary, triad, tetrad, analogous
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .complementary: return "Complementary"
        case .splitComplementary: return "Split-complementary"
        case .triad: return "Triad"
        case .tetrad: return "Tetrad"
        case .analogous: return "Analogous"
        }
    }
    /// The spokes, in degrees from the base hue.
    var offsets: [Double] {
        switch self {
        case .none: return []
        case .complementary: return [0, 180]
        case .splitComplementary: return [0, 150, 210]
        case .triad: return [0, 120, 240]
        case .tetrad: return [0, 60, 180, 240]
        case .analogous: return [-30, 0, 30]
        }
    }
    /// The spokes' angles for a base hue, each 0..<360.
    func angles(base: Double) -> [Double] {
        offsets.map { VectorscopeGeometry.normalised(base + $0) }
    }
}

/// Angles on the scope: degrees counter-clockwise from the +Cb axis
/// (right), with Cr up, the convention of broadcast vectorscopes.
enum VectorscopeGeometry {
    /// The skin-tone ("I") line: where every skin colour falls, whatever
    /// its depth, at about 123° on a Rec.709 scope.
    static let skinToneAngle: Double = 123

    static func normalised(_ degrees: Double) -> Double {
        let a = degrees.truncatingRemainder(dividingBy: 360)
        return a < 0 ? a + 360 : a
    }

    /// The angle of `point` about the centre of `rect`, in view space
    /// (y down).
    static func angle(of point: CGPoint, in rect: CGRect) -> Double {
        let dx = Double(point.x - rect.midX), dy = Double(rect.midY - point.y)
        return normalised(atan2(dy, dx) * 180 / .pi)
    }

    /// The point at `fraction` of the radius along `degrees`.
    static func point(angle degrees: Double, fraction: Double, in rect: CGRect) -> CGPoint {
        let r = Double(min(rect.width, rect.height)) / 2 * fraction
        let t = degrees * .pi / 180
        return CGPoint(x: Double(rect.midX) + r * cos(t), y: Double(rect.midY) - r * sin(t))
    }
}

/// The scope and colour picker settings: display preferences, never part
/// of an edit. In Preferences › Scopes and the scopes' own menus.
@MainActor
final class ScopeSettings: ObservableObject {
    static let shared = ScopeSettings()

    private let defaults: UserDefaults

    @Published var skinToneLine: Bool { didSet { defaults.set(skinToneLine, forKey: Keys.skinToneLine) } }
    @Published var harmony: HarmonyGuide { didSet { defaults.set(harmony.rawValue, forKey: Keys.harmony) } }
    /// The harmony's base hue, in degrees on the scope.
    @Published var harmonyAngle: Double { didSet { defaults.set(harmonyAngle, forKey: Keys.harmonyAngle) } }
    /// Pinned colour samples drawn as numbered dots on the vectorscope.
    @Published var plotsSamples: Bool { didSet { defaults.set(plotsSamples, forKey: Keys.plotsSamples) } }
    @Published var sampleSize: PixelSampleSize { didSet { defaults.set(sampleSize.rawValue, forKey: Keys.sampleSize) } }
    @Published var readoutSpace: PixelReadoutSpace { didSet { defaults.set(readoutSpace.rawValue, forKey: Keys.readoutSpace) } }

    enum Keys {
        static let skinToneLine = "latent.scopes.skinToneLine"
        static let harmony = "latent.scopes.harmony"
        static let harmonyAngle = "latent.scopes.harmonyAngle"
        static let plotsSamples = "latent.scopes.plotsSamples"
        static let sampleSize = "latent.picker.sampleSize"
        static let readoutSpace = "latent.picker.space"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        skinToneLine = defaults.bool(forKey: Keys.skinToneLine)
        harmony = HarmonyGuide(rawValue: defaults.string(forKey: Keys.harmony) ?? "") ?? .none
        harmonyAngle = defaults.object(forKey: Keys.harmonyAngle) as? Double ?? VectorscopeGeometry.skinToneAngle
        plotsSamples = defaults.object(forKey: Keys.plotsSamples) as? Bool ?? true
        sampleSize = PixelSampleSize(rawValue: defaults.integer(forKey: Keys.sampleSize)) ?? .point
        readoutSpace = PixelReadoutSpace(rawValue: defaults.string(forKey: Keys.readoutSpace) ?? "") ?? .standard
    }
}

/// The skin-tone line and harmony spokes, drawn into the vectorscope's
/// square. Wedges are 10° either side of each spoke, so a colour "on"
/// the harmony has some room.
enum VectorscopeGuideDrawing {
    static let wedgeHalfWidth: Double = 10

    static func draw(in context: inout GraphicsContext, rect: CGRect,
                     skinToneLine: Bool, harmony: HarmonyGuide, angle: Double) {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        for spoke in harmony.angles(base: angle) {
            var wedge = Path()
            wedge.move(to: centre)
            let steps = 8
            for i in 0...steps {
                let a = spoke - wedgeHalfWidth + 2 * wedgeHalfWidth * Double(i) / Double(steps)
                wedge.addLine(to: VectorscopeGeometry.point(angle: a, fraction: 1, in: rect))
            }
            wedge.closeSubpath()
            context.fill(wedge, with: .color(Color.white.opacity(0.07)))
            var line = Path()
            line.move(to: centre)
            line.addLine(to: VectorscopeGeometry.point(angle: spoke, fraction: 1, in: rect))
            context.stroke(line, with: .color(Color.white.opacity(spoke == VectorscopeGeometry.normalised(angle) ? 0.55 : 0.35)),
                           lineWidth: 1)
        }
        if skinToneLine {
            var line = Path()
            line.move(to: centre)
            line.addLine(to: VectorscopeGeometry.point(angle: VectorscopeGeometry.skinToneAngle, fraction: 1, in: rect))
            context.stroke(line, with: .color(Color(red: 1, green: 0.75, blue: 0.55).opacity(0.75)),
                           style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }
}

/// The vectorscope's right-click menu.
struct VectorscopeGuideMenu: View {
    @ObservedObject var settings: ScopeSettings

    var body: some View {
        Toggle("Skin Tone Line", isOn: $settings.skinToneLine)
        Picker("Harmony", selection: $settings.harmony) {
            ForEach(HarmonyGuide.allCases) { Text($0.title).tag($0) }
        }
        Button("Reset Harmony Angle") { settings.harmonyAngle = VectorscopeGeometry.skinToneAngle }
            .disabled(settings.harmony == .none)
        Divider()
        Toggle("Show Pinned Samples", isOn: $settings.plotsSamples)
    }
}

/// Preferences › Scopes.
struct ScopeSettingsTab: View {
    @ObservedObject var settings = ScopeSettings.shared

    var body: some View {
        Form {
            Section("Vectorscope") {
                Toggle("Skin tone line", isOn: $settings.skinToneLine)
                Picker("Harmony guide", selection: $settings.harmony) {
                    ForEach(HarmonyGuide.allCases) { Text($0.title).tag($0) }
                }
                Slider(value: $settings.harmonyAngle, in: 0...359, step: 1) {
                    Text("Harmony angle")
                } minimumValueLabel: { Text("0°") } maximumValueLabel: { Text("359°") }
                    .disabled(settings.harmony == .none)
                Toggle("Plot pinned colour samples", isOn: $settings.plotsSamples)
                Text("The skin tone line runs where skin of every depth falls. A harmony guide marks the hues that go with a base hue; drag on the vectorscope to turn it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Colour picker") {
                Picker("Sample size", selection: $settings.sampleSize) {
                    ForEach(PixelSampleSize.allCases) { Text($0.title).tag($0) }
                }
                Picker("Show as", selection: $settings.readoutSpace) {
                    ForEach(PixelReadoutSpace.allCases) { Text($0.title).tag($0) }
                }
                Text("A sample larger than a point reads the mean of a square of image pixels and its least and greatest values. Option-click the photo in Develop to pin up to eight samples.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
