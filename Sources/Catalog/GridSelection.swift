import Foundation
import CoreGraphics

/// The rules for the grid's lead image: the one Loupe, Develop and the
/// metadata panel show when several are selected. Plain functions of
/// positions and ids, so they're tested without a window.
///
/// Following minivu (and Finder): the lead is the item just clicked or
/// arrowed to. A shift-click or shift-arrow adds a run of items at once,
/// and the lead is the end that moved, not whichever item a `Set` happens
/// to yield first.
public enum GridSelection {
    /// The lead position after the grid's selection changed.
    ///
    /// - Parameters:
    ///   - previous: the old lead's position in the visible list, if any.
    ///   - added: positions that just became selected.
    ///   - selected: every selected position now.
    /// - Returns: the added position farthest from the old lead (for a plain
    ///   click, the one item clicked); with nothing added (a deselection),
    ///   the old lead if it's still selected, else the first selected.
    public static func lead(previous: Int?, added: some Collection<Int>, selected: Set<Int>) -> Int? {
        let anchor = previous ?? 0
        if let farthest = added.filter(selected.contains).max(by: { lhs, rhs in
            // Equal distances (either side of the anchor) go to the later one,
            // so the answer doesn't depend on the collection's order.
            let l = abs(lhs - anchor), r = abs(rhs - anchor)
            return l == r ? lhs < rhs : l < r
        }) {
            return farthest
        }
        if let previous, selected.contains(previous) { return previous }
        return selected.min()
    }

    /// The lead id for a selection set from outside the grid view: the
    /// proposed one if it's selected, else the current lead if it still is,
    /// else the first selected image in `order`.
    public static func resolvedLead(proposed: Int64?, current: Int64?, selected: Set<Int64>,
                                    order: [ImageRecord]) -> Int64? {
        if let proposed, selected.contains(proposed) { return proposed }
        if let current, selected.contains(current) { return current }
        guard !selected.isEmpty else { return nil }
        return order.first { $0.id.map(selected.contains) ?? false }?.id ?? selected.min()
    }
}

/// Cell geometry for one thumbnail size, in points, top-down (the cell's
/// view is flipped). Plain numbers so the layout is tested without views.
public struct ThumbnailGridLayout: Equatable, Sendable {
    /// Thumbnails are stored at 512 px, so 256 pt is the largest cell that
    /// stays sharp on a Retina screen.
    public static let sizeRange: ClosedRange<Double> = 80...256
    /// ⌘= and ⌘- move the size by this much, and the slider snaps to it.
    public static let sizeStep: Double = 16
    public static let defaultSide: Double = 160

    public static let inset: CGFloat = 4
    public static let labelGap: CGFloat = 4
    public static let nameHeight: CGFloat = 14
    /// The badge row (edited, flag, stars): always reserved, so rating an
    /// image doesn't make its row taller than its neighbours'.
    public static let badgeHeight: CGFloat = 13
    public static let bottomPadding: CGFloat = 7

    /// Side of the square thumbnail area.
    public let side: CGFloat

    public init(side: Double) {
        self.side = CGFloat(Self.clamped(side).rounded())
    }

    public var itemSize: CGSize {
        CGSize(width: side + 2 * Self.inset,
               height: Self.inset + side + Self.labelGap + Self.nameHeight + Self.badgeHeight + Self.bottomPadding)
    }

    public var thumbnailArea: CGRect { CGRect(x: Self.inset, y: Self.inset, width: side, height: side) }

    public var nameFrame: CGRect {
        CGRect(x: Self.inset, y: thumbnailArea.maxY + Self.labelGap, width: side, height: Self.nameHeight)
    }

    public var badgeFrame: CGRect {
        CGRect(x: 0, y: nameFrame.maxY, width: itemSize.width, height: Self.badgeHeight)
    }

    /// Pixels to ask the thumbnail loader for.
    public func pixelSize(backingScale: CGFloat) -> Int {
        Int((side * max(1, backingScale)).rounded())
    }

    /// Where a picture of `pixels` sits in the square: as large as fits,
    /// centred, snapped to whole points so edges stay crisp.
    public func imageFrame(for pixels: CGSize) -> CGRect {
        let rect = thumbnailArea
        guard pixels.width > 0, pixels.height > 0 else { return rect }
        let scale = min(rect.width / pixels.width, rect.height / pixels.height)
        let width = (pixels.width * scale).rounded(), height = (pixels.height * scale).rounded()
        return CGRect(x: (rect.midX - width / 2).rounded(), y: (rect.midY - height / 2).rounded(),
                      width: width, height: height)
    }

    public static func clamped(_ size: Double) -> Double {
        min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
    }

    /// The next size up or down, on multiples of the step so repeated
    /// presses land on round numbers whatever the slider left.
    public static func stepped(_ size: Double, larger: Bool) -> Double {
        let steps = size / sizeStep
        let next = larger ? (steps + 0.001).rounded(.down) + 1 : (steps - 0.001).rounded(.up) - 1
        return clamped(next * sizeStep)
    }
}

extension LibraryFilter {
    /// Whether a record changing from `old` to `new` could change whether
    /// it passes. A rating change under a flag filter can't, so the grid
    /// needn't filter the whole folder again for it.
    public func dependsOnChange(from old: ImageRecord, to new: ImageRecord) -> Bool {
        if minRating > 0, old.rating != new.rating { return true }
        if !flags.isEmpty, old.flag != new.flag { return true }
        if camera != nil, old.camera != new.camera { return true }
        if lens != nil, old.lens != new.lens { return true }
        if !text.trimmingCharacters(in: .whitespaces).isEmpty, old.relPath != new.relPath { return true }
        return false
    }
}

extension LibrarySort {
    /// Whether a record changing from `old` to `new` could move it in this
    /// order. The path breaks ties in every order, so it always counts.
    public func dependsOnChange(from old: ImageRecord, to new: ImageRecord) -> Bool {
        if old.relPath != new.relPath { return true }
        switch key {
        case .captureTime: return old.captureTime != new.captureTime
        case .rating: return old.rating != new.rating
        case .modified: return old.mtime != new.mtime
        case .fileName: return false
        }
    }
}
