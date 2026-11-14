import AppKit
import Catalog
import PixelEngine

/// The five stars under a grid thumbnail, for rating with the mouse.
///
/// At rest only the stars an image has are drawn, so an unrated folder
/// stays quiet. With the pointer over the cell the empty ones appear
/// hollow; over a star, the stars up to it light up to preview the rating
/// a click sets. Clicking the image's current rating clears it.
///
/// The view takes the click itself (it doesn't pass mouseDown on), so a
/// click on a star never starts a drag or a rubber band. What the click
/// rates, the one image or the whole selection, the grid decides
/// (`ThumbnailGridView.Coordinator.rate`). Not an accessibility element:
/// the cell reads as one image, and offers the ratings as actions.
final class StarRatingView: NSView {
    var rating = 0 {
        didSet { if rating != oldValue { needsDisplay = true } }
    }
    /// The pointer is somewhere over the cell.
    var isCellHovered = false {
        didSet {
            if isCellHovered != oldValue { needsDisplay = true }
            // A cell reused, or left, under the pointer shows no preview.
            if !isCellHovered { hoveredStar = nil }
        }
    }
    /// The star the pointer is over, 1...5.
    private(set) var hoveredStar: Int? {
        didSet { if hoveredStar != oldValue { needsDisplay = true } }
    }
    /// A star was clicked: the star's number, 1...5.
    var onClick: ((Int) -> Void)?

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { hoveredStar = nil }

    private func track(_ event: NSEvent) {
        hoveredStar = ThumbnailGridLayout.star(atX: convert(event.locationInWindow, from: nil).x)
    }

    override func mouseDown(with event: NSEvent) {
        guard let star = ThumbnailGridLayout.star(atX: convert(event.locationInWindow, from: nil).x) else { return }
        onClick?(star)
    }

    /// Clicks in an inactive window rate straight away, as a click on the
    /// panel's stars does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// What each star shows: filled, hollow or nothing, and whether it is
    /// the hover preview.
    enum Glyph: Equatable { case none, hollow, filled, preview }

    static func glyphs(rating: Int, cellHovered: Bool, hoveredStar: Int?) -> [Glyph] {
        (1...ThumbnailGridLayout.starCount).map { star in
            if let hoveredStar { return star <= hoveredStar ? .preview : .hollow }
            if star <= rating { return .filled }
            return cellHovered ? .hollow : .none
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let glyphs = Self.glyphs(rating: rating, cellHovered: isCellHovered, hoveredStar: hoveredStar)
        let font = NSFont.systemFont(ofSize: 9)
        let filled = Contrast.isIncreased ? NSColor.labelColor : NSColor.secondaryLabelColor
        for (index, glyph) in glyphs.enumerated() where glyph != .none {
            let text = glyph == .hollow ? "☆" : "★"
            let color: NSColor = switch glyph {
            case .preview: .controlAccentColor
            case .hollow: .tertiaryLabelColor
            default: filled
            }
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
            let size = string.size()
            let slot = CGRect(x: CGFloat(index) * ThumbnailGridLayout.starWidth, y: 0,
                              width: ThumbnailGridLayout.starWidth, height: bounds.height)
            string.draw(at: CGPoint(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2))
        }
    }
}

/// Up to three Finder tag dots, overlapping as Finder draws them, each cut
/// out of the one before by a ring of the cell's background so they stay
/// apart. A tag without a colour is a hollow ring.
final class TagDotsView: NSView {
    var tags: [FinderTag] = [] {
        didSet { if tags != oldValue { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let diameter = ThumbnailGridLayout.tagDotDiameter
        // The last tags are drawn first, so the first tag sits on top at the left.
        let shown = Array(tags.prefix(ThumbnailGridLayout.maximumTagDots))
        for (index, tag) in shown.enumerated().reversed() {
            let rect = CGRect(x: CGFloat(index) * ThumbnailGridLayout.tagDotStep, y: 0, width: diameter, height: diameter)
            // Punch out a slightly larger circle first, so the dot beneath
            // shows a gap rather than running into this one.
            context.saveGState()
            context.setBlendMode(.clear)
            context.fillEllipse(in: rect.insetBy(dx: -1, dy: -1))
            context.restoreGState()
            if let color = tag.nsColor {
                color.setFill()
                NSBezierPath(ovalIn: rect).fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
        }
    }
}

/// A small tag in the badge row for a photo with keywords. Its tooltip
/// lists them.
final class KeywordBadgeView: NSView {
    /// The keywords as shown, sorted; the badge hides with none.
    private(set) var keywords: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Sets the keywords (stored paths); true when they changed.
    @discardableResult
    func setKeywords(_ stored: Set<String>) -> Bool {
        let shown = stored.map(KeywordPath.display).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard shown != keywords else { return false }
        keywords = shown
        toolTip = Self.toolTip(shown)
        needsDisplay = true
        return true
    }

    /// "Keywords: Paris, Places › France".
    static func toolTip(_ keywords: [String]) -> String? {
        keywords.isEmpty ? nil : "Keywords: " + keywords.joined(separator: ", ")
    }

    override func draw(_ dirtyRect: NSRect) {
        let colour = Contrast.isIncreased ? NSColor.labelColor : NSColor.secondaryLabelColor
        let configuration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [colour]))
        guard !keywords.isEmpty,
              let symbol = NSImage(systemSymbolName: "tag.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return }
        let size = symbol.size
        let rect = CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                          width: size.width, height: size.height)
        symbol.draw(in: rect)
    }
}

/// An invisible patch over the edited pencil that carries its tooltip:
/// the edit groups the photo's edit changes. They are read from the
/// catalog when the pointer arrives, not for every cell scrolled past.
final class EditedBadgeTipView: NSView {
    /// Asked when the pointer comes over the pencil; calls back with the text.
    var loadToolTip: ((@escaping @MainActor (String?) -> Void) -> Void)?
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        loadToolTip? { [weak self] text in self?.toolTip = text }
    }

    // No hitTest override: the tooltip needs the view found under the
    // pointer. Clicks still reach the grid, since a plain NSView passes
    // its mouse events on to the next responder.
}

/// The edit groups a stored edit changes from the defaults, for the edited
/// pencil's tooltip: each group taken alone from the edit, compared with a
/// fresh stack, the way copy and paste see the groups.
enum EditedGroupsSummary {
    static func changedGroups(json: String) -> [EditGroup] {
        guard let stack = try? EditStack.decode(json: json) else { return [] }
        let base = EditStack()
        return EditGroup.allCases.filter { base.merged(with: stack, groups: [$0]) != base }
    }

    /// "Edited: White Balance, Tone, Crop & Straighten".
    static func toolTip(_ groups: [EditGroup]) -> String {
        guard !groups.isEmpty else { return "Edited" }
        return "Edited: " + groups.map(shortName).joined(separator: ", ")
    }

    /// The group's name without the parenthesis that lists its sliders.
    static func shortName(_ group: EditGroup) -> String {
        group.displayName.components(separatedBy: " (").first ?? group.displayName
    }
}
