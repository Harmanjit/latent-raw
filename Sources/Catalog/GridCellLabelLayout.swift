import CoreGraphics

/// Where a grid cell's colour label dot goes: in the badge row, just left
/// of the stars, where the eye already looks for a photo's marks.
extension ThumbnailGridLayout {
    public static let labelDotDiameter: CGFloat = 7
    /// Space between the dot and the first star.
    static let labelDotGap: CGFloat = 3

    public var labelDotFrame: CGRect {
        let d = Self.labelDotDiameter
        return CGRect(x: starsFrame.minX - Self.labelDotGap - d,
                      y: badgeFrame.minY + (Self.badgeHeight - d) / 2, width: d, height: d)
    }

    /// The edited and flag badges, narrowed to leave room for the dot when
    /// the photo has a label.
    public func flagBadgeFrame(hasLabel: Bool) -> CGRect {
        var frame = flagBadgeFrame
        if hasLabel { frame.size.width = max(0, labelDotFrame.minX - Self.inset - 2) }
        return frame
    }
}
