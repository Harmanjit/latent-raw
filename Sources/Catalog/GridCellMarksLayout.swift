import CoreGraphics

/// Where the marks under a grid cell's thumbnail go: the clickable stars at
/// the right of the badge row, the edited and flag badges at its left, and
/// up to three Finder tag dots at the end of the name row. Plain numbers,
/// like the rest of the cell's layout, so they are tested without views.
extension ThumbnailGridLayout {
    /// Width of one star's click target. Five of them fit beside the flag
    /// and edited badges in the smallest cell.
    public static let starWidth: CGFloat = 10
    public static let starCount = 5
    /// Tag dots overlap as Finder's do: each one this far right of the last.
    public static let tagDotDiameter: CGFloat = 8
    public static let tagDotStep: CGFloat = 5
    public static let maximumTagDots = 3

    /// The five stars, right-aligned under the thumbnail.
    public var starsFrame: CGRect {
        let width = Self.starWidth * CGFloat(Self.starCount)
        return CGRect(x: thumbnailArea.maxX - width, y: badgeFrame.minY, width: width, height: Self.badgeHeight)
    }

    /// The edited and flag badges, left of the stars.
    public var flagBadgeFrame: CGRect {
        CGRect(x: Self.inset, y: badgeFrame.minY, width: max(0, starsFrame.minX - Self.inset - 2),
               height: Self.badgeHeight)
    }

    /// Which star (1...5) a point in the stars' own coordinates is over;
    /// nil outside them.
    public static func star(atX x: CGFloat) -> Int? {
        guard x >= 0, x < starWidth * CGFloat(starCount) else { return nil }
        return Int(x / starWidth) + 1
    }

    /// The rating a click on `star` sets: that many stars, or none when the
    /// image already has exactly that many.
    public static func rating(afterClicking star: Int, current: Int) -> Int {
        star == current ? 0 : min(max(star, 0), starCount)
    }

    /// Width the dots of `tagCount` tags take (at most three are drawn).
    public static func tagDotsWidth(tagCount: Int) -> CGFloat {
        let shown = min(tagCount, maximumTagDots)
        return shown == 0 ? 0 : tagDotDiameter + tagDotStep * CGFloat(shown - 1)
    }

    /// The name, narrowed to leave room for the tag dots after it.
    public func nameFrame(tagCount: Int) -> CGRect {
        let dots = Self.tagDotsWidth(tagCount: tagCount)
        var frame = nameFrame
        if dots > 0 { frame.size.width = max(0, frame.width - dots - 3) }
        return frame
    }

    /// The tag dots, at the right end of the name row, centred on its height.
    public func tagDotsFrame(tagCount: Int) -> CGRect {
        let width = Self.tagDotsWidth(tagCount: tagCount)
        return CGRect(x: nameFrame.maxX - width, y: nameFrame.midY - Self.tagDotDiameter / 2,
                      width: width, height: Self.tagDotDiameter)
    }
}

/// View › Grid Marks: how much of a cell's marks show. Always is the grid
/// as it has always looked, and the default.
public enum GridMarksMode: String, CaseIterable, Sendable {
    case always, onHover, minimal, extended

    public var title: String {
        switch self {
        case .always: "Always"
        case .onHover: "On Hover"
        case .minimal: "Minimal"
        case .extended: "Extended"
        }
    }

    /// Which marks a cell shows in this mode, with the pointer over it or not.
    public func visibility(hovered: Bool) -> GridMarkVisibility {
        switch self {
        case .always: .all
        case .extended: GridMarkVisibility(infoLine: true)
        case .onHover: hovered ? .all : .none
        case .minimal:
            // The selection (the cell's own fill), the flag and the label dot.
            GridMarkVisibility(name: false, stars: false, editedBadge: false, tagDots: false,
                               keywordBadge: false, pictureBadges: false)
        }
    }
}

/// The marks a grid cell shows (`GridMarksMode.visibility`). The damaged
/// file badge is a warning and always shows.
public struct GridMarkVisibility: Equatable, Sendable {
    public var name = true
    public var stars = true
    public var flagBadge = true
    public var editedBadge = true
    public var labelDot = true
    public var tagDots = true
    public var keywordBadge = true
    /// The virtual-copy and stack marks on the picture.
    public var pictureBadges = true
    /// Extended's line of shooting data on the picture.
    public var infoLine = false

    public init(name: Bool = true, stars: Bool = true, flagBadge: Bool = true, editedBadge: Bool = true,
                labelDot: Bool = true, tagDots: Bool = true, keywordBadge: Bool = true,
                pictureBadges: Bool = true, infoLine: Bool = false) {
        self.name = name
        self.stars = stars
        self.flagBadge = flagBadge
        self.editedBadge = editedBadge
        self.labelDot = labelDot
        self.tagDots = tagDots
        self.keywordBadge = keywordBadge
        self.pictureBadges = pictureBadges
        self.infoLine = infoLine
    }

    public static let all = GridMarkVisibility()
    public static let none = GridMarkVisibility(name: false, stars: false, flagBadge: false, editedBadge: false,
                                                labelDot: false, tagDots: false, keywordBadge: false,
                                                pictureBadges: false)
}

extension ThumbnailGridLayout {
    /// The keyword badge: a small tag in the badge row, just left of the
    /// label dot (or of the stars when there's no label).
    public static let keywordBadgeWidth: CGFloat = 10
    static let keywordBadgeGap: CGFloat = 2

    public func keywordBadgeFrame(hasLabel: Bool) -> CGRect {
        let right = hasLabel ? labelDotFrame.minX : starsFrame.minX - Self.labelDotGap + Self.keywordBadgeGap
        return CGRect(x: right - Self.keywordBadgeGap - Self.keywordBadgeWidth, y: badgeFrame.minY,
                      width: Self.keywordBadgeWidth, height: Self.badgeHeight)
    }

    /// The edited and flag badges, narrowed for the label dot and, when the
    /// photo has keywords, the keyword badge. Without keywords it is
    /// `flagBadgeFrame(hasLabel:)`, as before.
    public func flagBadgeFrame(hasLabel: Bool, hasKeywords: Bool) -> CGRect {
        var frame = flagBadgeFrame(hasLabel: hasLabel)
        if hasKeywords { frame.size.width = max(0, keywordBadgeFrame(hasLabel: hasLabel).minX - Self.inset - 2) }
        return frame
    }

    /// Where the edited pencil sits, the first glyph of the badge text, for
    /// its tooltip.
    public var editedBadgeFrame: CGRect {
        CGRect(x: Self.inset, y: badgeFrame.minY, width: 10, height: Self.badgeHeight)
    }

    /// Extended's shooting-data line, along the bottom of the picture.
    public static let infoLineHeight: CGFloat = 13

    public static func infoLineFrame(inImageFrame image: CGRect) -> CGRect {
        let height = min(infoLineHeight, image.height)
        return CGRect(x: image.minX, y: image.maxY - height, width: image.width, height: height)
    }
}
