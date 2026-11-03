import Foundation

/// The five colour labels, as Lightroom and Bridge write them in
/// `xmp:Label`. A label is a word, not a number, so the sidecar says "Red"
/// and any of those applications reads it back as red.
///
/// The catalog stores whatever text a sidecar had (`ImageRecord.label`): a
/// label another application wrote under a name of its own ("Approved",
/// say) is kept as it is and shown as a custom label rather than dropped.
public enum ColorLabel: String, CaseIterable, Sendable, Hashable {
    case red = "Red"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"

    /// The label a stored `xmp:Label` names, whatever its letter case; nil
    /// for none and for a custom label.
    public init?(xmpLabel: String?) {
        guard let text = xmpLabel?.trimmingCharacters(in: .whitespaces), !text.isEmpty,
              let match = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(text) == .orderedSame })
        else { return nil }
        self = match
    }

    /// What `xmp:Label` holds for this label.
    public var xmpValue: String { rawValue }

    public var title: String { rawValue }

    /// The label a key sets: 6 red, 7 yellow, 8 green, 9 blue, as in
    /// Lightroom. Purple has no key there either.
    public static func forKey(_ digit: Int) -> ColorLabel? {
        switch digit {
        case 6: .red
        case 7: .yellow
        case 8: .green
        case 9: .blue
        default: nil
        }
    }

    /// The label after choosing `chosen` on photos whose primary has
    /// `current`: choosing the label it already has takes it off, as the
    /// keys do in Lightroom; nil chosen clears.
    public static func label(afterChoosing chosen: ColorLabel?, current: String?) -> String? {
        guard let chosen else { return nil }
        return ColorLabel(xmpLabel: current) == chosen ? nil : chosen.xmpValue
    }
}

/// One of the label filter's choices. Several may be on at once and an
/// image passes when it matches any of them, as Lightroom's label filter
/// works.
public enum LabelFilterChoice: Hashable, Sendable {
    case color(ColorLabel)
    /// No label at all.
    case none
    /// A label that isn't one of the five (written by another application).
    case custom

    /// Whether an image with stored label `label` passes this choice.
    public func matches(_ label: String?) -> Bool {
        let text = label?.trimmingCharacters(in: .whitespaces) ?? ""
        switch self {
        case .color(let color): return ColorLabel(xmpLabel: text) == color
        case .none: return text.isEmpty
        case .custom: return !text.isEmpty && ColorLabel(xmpLabel: text) == nil
        }
    }

    public static let all: [LabelFilterChoice] = ColorLabel.allCases.map { .color($0) } + [.none, .custom]

    public var title: String {
        switch self {
        case .color(let color): color.title
        case .none: "No Label"
        case .custom: "Custom Label"
        }
    }
}
