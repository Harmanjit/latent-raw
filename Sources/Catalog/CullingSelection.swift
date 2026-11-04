import Foundation

/// Edit › Select by…, Invert Selection and Deselect Unflagged, as in
/// Lightroom's Library: a new grid selection worked out from the visible
/// photos and their flags, stars and labels. Plain functions of records,
/// so they're tested without a window.
public enum CullingSelection: Hashable, Sendable {
    /// Edit › Select None.
    case none
    /// Every visible photo that isn't selected, and none that is.
    case invert
    /// Select by Flag: the photos with exactly this flag.
    case flag(ImageFlag)
    /// Select by Rating: the photos with exactly this many stars (0 for none).
    case rating(Int)
    /// Select by Colour Label: the photos with this label, nil for no label.
    case label(ColorLabel?)
    /// Takes the unflagged photos out of the selection, keeping the picked
    /// and the rejected.
    case deselectUnflagged

    /// The ids selected after the command, from `visible` (the grid's list)
    /// and the ids selected now. Photos the filter hides are never selected,
    /// and a selected one hidden since is dropped, as everywhere in the grid.
    public func selection(in visible: [ImageRecord], current: Set<Int64>) -> Set<Int64> {
        func ids(_ include: (ImageRecord) -> Bool) -> Set<Int64> {
            Set(visible.lazy.filter(include).compactMap(\.id))
        }
        switch self {
        case .none:
            return []
        case .invert:
            return ids { !($0.id.map(current.contains) ?? false) }
        case .flag(let flag):
            return ids { $0.flag == flag.rawValue }
        case .rating(let stars):
            let stars = min(max(stars, 0), 5)
            return ids { min(max($0.rating, 0), 5) == stars }
        case .label(let label):
            return ids { ColorLabel(xmpLabel: $0.label) == label && (label != nil || Self.hasNoLabel($0)) }
        case .deselectUnflagged:
            return ids { ($0.id.map(current.contains) ?? false) && $0.flag != ImageFlag.none.rawValue }
        }
    }

    /// No label at all: a custom label isn't one of the five colours, but
    /// it isn't "no label" either.
    private static func hasNoLabel(_ record: ImageRecord) -> Bool {
        (record.label ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Library › Refine Photos, as Lightroom does it: over the photos shown,
/// every unflagged one becomes rejected and every picked one unflagged.
/// Rejected photos stay rejected. Run twice, it leaves only the photos
/// picked both times unflagged and everything else rejected.
public struct RefinePlan: Equatable, Sendable {
    /// Image id → the flag it gets.
    public var changes: [Int64: ImageFlag]

    public init(visible: [ImageRecord]) {
        var changes: [Int64: ImageFlag] = [:]
        for record in visible {
            guard let id = record.id else { continue }
            switch ImageFlag(rawValue: record.flag) ?? ImageFlag.none {
            case .none: changes[id] = .rejected
            case .picked: changes[id] = ImageFlag.none
            case .rejected: break
            }
        }
        self.changes = changes
    }

    public var rejectedCount: Int { changes.values.filter { $0 == .rejected }.count }
    public var unflaggedCount: Int { changes.values.filter { $0 == ImageFlag.none }.count }
    public var isEmpty: Bool { changes.isEmpty }
}

extension Library {
    /// The images a rating, flag or label key would change right now. The
    /// app reads them before Auto Advance moves the selection on, so the
    /// write lands on the photo the key was pressed on.
    public func cullingTargets(onlyPrimary: Bool) -> [ImageRecord] {
        metadataTargets(onlyPrimary: onlyPrimary)
    }

    /// Replaces the grid selection by one of the Select commands. The lead
    /// stays where it is if it's still selected.
    public func applySelection(_ command: CullingSelection) {
        setSelection(command.selection(in: visibleImages, current: selectedImageIDs), primary: selectedImageID)
    }

    /// Refine Photos over the visible photos, in one undoable step. Returns
    /// the plan carried out (the app asks first, with the same counts).
    @discardableResult
    public func refinePhotos() async throws -> RefinePlan {
        let plan = RefinePlan(visible: visibleImages)
        let written = catalog, before = UndoLedger<Int>()
        defer {
            let changed = before.recorded.filter { plan.changes[$0.key]?.rawValue != $0.value }
            fileFreshUndo("Refine Photos", count: changed.count, in: written,
                          undo: .flag(changed),
                          redo: .flag(changed.reduce(into: [Int64: Int]()) { $0[$1.key] = plan.changes[$1.key]?.rawValue }))
        }
        let records = visibleImages.filter { $0.id.map { plan.changes[$0] != nil } ?? false }
        let changes = plan.changes
        try await change(records) { catalog, id, _ in
            guard let flag = changes[id] else { return }
            if let previous = try await catalog.exchangeFlag(flag, forImageID: id) { before.record(id, previous) }
        }
        return plan
    }
}
