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
