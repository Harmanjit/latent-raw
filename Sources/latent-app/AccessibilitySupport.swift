import AppKit
import SwiftUI

/// System Settings > Accessibility > Display > Reduce Motion, read where it
/// is used, so turning it on applies to the next scroll or panel change
/// without relaunching (minivu's Motion). SwiftUI views read the same
/// setting from `\.accessibilityReduceMotion` and pass it in.
enum Motion {
    static var isReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// `animation`, or none at all under Reduce Motion: things jump to
    /// where they are going instead of sliding there.
    static func animation(_ animation: Animation?, reduced: Bool = isReduced) -> Animation? {
        reduced ? nil : animation
    }

    /// A transition that moves the view becomes a cross-fade.
    static func transition(_ transition: AnyTransition, reduced: Bool = isReduced) -> AnyTransition {
        reduced ? .opacity : transition
    }

    /// How long an AppKit scroll glides for; 0 means jump.
    static func scrollDuration(_ duration: TimeInterval, reduced: Bool = isReduced) -> TimeInterval {
        reduced ? 0 : duration
    }
}

/// System Settings > Accessibility > Display > Increase Contrast. A tinted
/// fill on the user's chosen surround is easy to miss, so selections get a
/// solid outline as well while it is on.
enum Contrast {
    static var isIncreased: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Width of the outline drawn around a selection, 0 for none.
    static func selectionOutlineWidth(selected: Bool, increased: Bool = isIncreased) -> CGFloat {
        selected && increased ? 2 : 0
    }
}

/// Spoken status changes, for things a VoiceOver user would otherwise
/// only find by going to look: an export finishing, an error appearing.
@MainActor
enum Announcement {
    static func post(_ message: String, priority: NSAccessibilityPriorityLevel = .medium) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let app = NSApp else { return }
        let element: Any = app.mainWindow ?? app
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: priority.rawValue])
    }
}

/// What VoiceOver says for marks and readouts that are glyphs or pictures
/// on screen (★, ✓, ↺, a histogram), so every view says them the same way.
enum SpokenText {
    /// "No rating", "1 star", "3 stars".
    static func stars(_ rating: Int) -> String {
        let n = max(0, min(rating, 5))
        return n == 0 ? "No rating" : n == 1 ? "1 star" : "\(n) stars"
    }

    /// The rating filter's threshold: "Any rating", "3 stars or more".
    static func minimumRating(_ rating: Int) -> String {
        rating <= 0 ? "Any rating" : rating >= 5 ? "5 stars" : "\(stars(rating)) or more"
    }

    /// Picked, rejected or unflagged, for a flag's raw value.
    static func flag(_ flag: Int) -> String {
        flag > 0 ? "Picked" : flag < 0 ? "Rejected" : "Unflagged"
    }

    /// One image as a grid cell or filmstrip frame reads it:
    /// "DSC_0107.NEF, picked, 3 stars, edited". Unrated and unflagged say
    /// nothing, as the cell shows nothing.
    static func image(name: String, rating: Int, flag: Int, isEdited: Bool) -> String {
        var parts = [name]
        if flag != 0 { parts.append(Self.flag(flag).lowercased()) }
        if rating > 0 { parts.append(stars(rating).lowercased()) }
        if isEdited { parts.append("edited") }
        return parts.joined(separator: ", ")
    }

    /// The caption under a Loupe or Compare image, with the exposure's
    /// middle dots read as pauses: "Candidate, DSC_0107.NEF, 1/250 s, f/4,
    /// picked, 3 stars".
    static func caption(title: String?, name: String?, exposure: String, rating: Int, flag: Int) -> String {
        var parts: [String] = []
        if let title { parts.append(title) }
        guard let name else { return (parts + ["nothing selected"]).joined(separator: ", ") }
        parts.append(name)
        parts += exposure.components(separatedBy: " · ").filter { !$0.isEmpty }
        if flag != 0 { parts.append(Self.flag(flag).lowercased()) }
        if rating > 0 { parts.append(stars(rating).lowercased()) }
        return parts.joined(separator: ", ")
    }

    /// "Fit", or "150 percent", from the status bar's "150%".
    static func zoom(_ label: String) -> String {
        label.hasSuffix("%") ? String(label.dropLast()) + " percent" : label
    }

    /// The spot-removal patches on the image: "No patches", "3 patches,
    /// patch 2 selected".
    static func healPatches(count: Int, selected: Int?) -> String {
        guard count > 0 else { return "No patches" }
        var text = count == 1 ? "1 patch" : "\(count) patches"
        if let selected, selected >= 0, selected < count { text += ", patch \(selected + 1) selected" }
        return text
    }

    /// The crop rectangle: "4000 by 3000 pixels, aspect 4:3, straightened 1.5 degrees".
    static func crop(width: Int, height: Int, aspect: String, angle: Float) -> String {
        var text = "\(width) by \(height) pixels, aspect \(aspect)"
        if abs(angle) >= 0.005 {
            var degrees = String(format: "%.2f", angle)
            while degrees.hasSuffix("0") { degrees.removeLast() }
            if degrees.hasSuffix(".") { degrees.removeLast() }
            text += ", straightened \(degrees) degrees"
        }
        return text
    }

    /// Where a histogram's pixels sit, from its luminance bins, in quarters
    /// of the tonal range: "shadows 20 percent, midtones 55 percent,
    /// highlights 25 percent". The shape is the useful thing, and this is
    /// the part of it that reads as words.
    static func histogram(luminance bins: [UInt32]) -> String {
        let total = bins.reduce(0) { $0 + Double($1) }
        guard total > 0, bins.count >= 4 else { return "No data" }
        let quarter = bins.count / 4
        let shadows = bins[..<quarter].reduce(0) { $0 + Double($1) }
        let highlights = bins[(bins.count - quarter)...].reduce(0) { $0 + Double($1) }
        let percent = { (part: Double) in Int((part / total * 100).rounded()) }
        let low = percent(shadows), high = percent(highlights)
        return "shadows \(low) percent, midtones \(max(0, 100 - low - high)) percent, highlights \(high) percent"
    }
}

extension View {
    /// Under Reduce Motion nothing in this view animates: disclosure groups
    /// open, panels appear and the sidebar collapses in one step.
    func motionFollowsAccessibility() -> some View {
        modifier(ReduceMotionTransaction())
    }

    /// A solid accent outline around a selected row while Increase Contrast
    /// is on, over its tinted fill.
    func selectionOutline(_ selected: Bool, cornerRadius: CGFloat) -> some View {
        modifier(SelectionOutline(selected: selected, cornerRadius: cornerRadius))
    }
}

private struct ReduceMotionTransaction: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transaction { transaction in
            if reduceMotion { transaction.animation = Motion.animation(transaction.animation, reduced: true) }
        }
    }
}

private struct SelectionOutline: ViewModifier {
    let selected: Bool
    let cornerRadius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let width = Contrast.selectionOutlineWidth(selected: selected, increased: contrast == .increased)
        content.overlay {
            if width > 0 {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: width)
                    .accessibilityHidden(true)
            }
        }
    }
}
