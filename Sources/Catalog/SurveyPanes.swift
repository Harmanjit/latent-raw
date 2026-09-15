import Foundation
import CoreGraphics

/// What Survey shows: two to four selected images side by side, and which
/// of them has the keyboard. Plain values, so the rules for focus, removal
/// and following the grid's selection are tested without windows (after
/// minivu's CompareModel).
///
/// Survey is a view of the grid selection, as in Lightroom: every pane is
/// a selected image and the focused pane is the primary selection, so
/// rating and flag keys, which act on the primary outside the grid, act on
/// the focused pane. Removing a pane deselects its image.
public struct SurveyPanes: Equatable, Sendable {
    /// How many images Survey shows.
    public static let paneRange = 2...4

    /// The images on screen, one per pane, in grid order.
    public private(set) var ids: [Int64]
    /// The pane keys act on; always one of `ids`.
    public private(set) var focusedID: Int64

    /// Whether a selection of `count` images can be surveyed.
    public static func canSurvey(selectionCount count: Int) -> Bool {
        paneRange.contains(count)
    }

    /// The selection as panes: in `order` (the grid's), with selected ids
    /// the order doesn't list (hidden by the filter) after it. Focus starts
    /// on `primary` when it is selected, else on the first pane. Nil unless
    /// two to four images are selected.
    public init?(selected: Set<Int64>, primary: Int64?, order: [Int64]) {
        guard Self.canSurvey(selectionCount: selected.count) else { return nil }
        var seen: Set<Int64> = []
        var ids = order.filter { selected.contains($0) && seen.insert($0).inserted }
        ids += selected.subtracting(seen).sorted()
        self.ids = ids
        focusedID = primary.flatMap { selected.contains($0) ? $0 : nil } ?? ids[0]
    }

    public var focusedIndex: Int { ids.firstIndex(of: focusedID) ?? 0 }

    // MARK: - Focus

    /// Focuses the pane showing `id`; false if no pane does.
    @discardableResult
    public mutating func focus(_ id: Int64) -> Bool {
        guard ids.contains(id) else { return false }
        focusedID = id
        return true
    }

    /// ← and →: the previous or next pane, stopping at the ends. False when
    /// the focus stayed where it was.
    @discardableResult
    public mutating func moveFocus(by offset: Int) -> Bool {
        let target = min(max(focusedIndex + offset, 0), ids.count - 1)
        guard ids[target] != focusedID else { return false }
        focusedID = ids[target]
        return true
    }

    // MARK: - Removing

    /// Takes the pane showing `id` away. The focus, if it was there, moves
    /// to the pane that takes its place, or the one before at the end.
    /// False if no pane showed `id`. May leave fewer than two panes; the
    /// caller then leaves Survey (see `isComplete`).
    @discardableResult
    public mutating func remove(_ id: Int64) -> Bool {
        guard let index = ids.firstIndex(of: id) else { return false }
        ids.remove(at: index)
        if focusedID == id, !ids.isEmpty {
            focusedID = ids[min(index, ids.count - 1)]
        }
        return true
    }

    /// Two or more panes: still a survey. With one left it is a loupe.
    public var isComplete: Bool { ids.count >= Self.paneRange.lowerBound }

    /// Follows a selection changed from outside Survey's own clicks and
    /// keys (a rating under a filter that hides the image deselects it,
    /// say). Panes whose images are no longer selected go; images newly
    /// selected don't join. The focus follows `primary` when it is shown,
    /// else stays, else moves as `remove` moves it. Returns the ids removed.
    @discardableResult
    public mutating func follow(selected: Set<Int64>, primary: Int64?) -> [Int64] {
        let gone = ids.filter { !selected.contains($0) }
        for id in gone { remove(id) }
        if let primary, ids.contains(primary) { focusedID = primary }
        return gone
    }

    // MARK: - Layout

    /// Columns and rows for `count` panes in `size`: whichever arrangement
    /// shows each image largest, an image being `imageAspect` wide per unit
    /// high, a caption `captionHeight` tall under each pane and panes
    /// `spacing` apart. Ties go to fewer rows. Two images side by side in a
    /// wide window, four in a 2 × 2 grid, and three in a row only when the
    /// window is wide enough that a row beats a grid with a gap.
    public static func grid(count: Int, in size: CGSize, imageAspect: CGFloat = 1.5,
                            captionHeight: CGFloat = 0, spacing: CGFloat = 0) -> (columns: Int, rows: Int) {
        guard count > 1, size.width > 0, size.height > 0, imageAspect > 0 else { return (max(count, 1), 1) }
        var best = (columns: count, rows: 1)
        var bestArea: CGFloat = -1
        // Most columns first, so a tie keeps the arrangement with fewer rows.
        for columns in stride(from: count, through: 1, by: -1) {
            let rows = (count + columns - 1) / columns
            let width = (size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
            let height = (size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows) - captionHeight
            guard width > 0, height > 0 else { continue }
            let imageWidth = min(width, height * imageAspect)
            let area = imageWidth * (imageWidth / imageAspect)
            // Strictly larger by a hair, so float noise doesn't pick more rows.
            if area > bestArea * 1.0001 {
                best = (columns, rows)
                bestArea = area
            }
        }
        return best
    }

    /// Pane frames in `size` (top-left origin), in pane order, left to
    /// right then top to bottom, `spacing` apart and rounded to whole
    /// points so borders stay crisp.
    public static func frames(count: Int, columns: Int, rows: Int, in size: CGSize, spacing: CGFloat) -> [CGRect] {
        guard count > 0, columns > 0, rows > 0 else { return [] }
        let width = (size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        return (0..<count).map { i in
            let column = CGFloat(i % columns), row = CGFloat(i / columns)
            let x = (column * (width + spacing)).rounded()
            let y = (row * (height + spacing)).rounded()
            let maxX = (column * (width + spacing) + width).rounded()
            let maxY = (row * (height + spacing) + height).rounded()
            return CGRect(x: x, y: y, width: max(0, maxX - x), height: max(0, maxY - y))
        }
    }
}
