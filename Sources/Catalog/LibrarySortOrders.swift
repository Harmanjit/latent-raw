import Foundation

/// When an image's edit was last saved and how many steps its history
/// holds, for the Edit time and Edit count sorts. Read from the `edits`
/// and `history` tables (`Catalog.editStats`); an image without a stored
/// edit has none.
public struct LibraryEditStat: Equatable, Sendable {
    /// Milliseconds since 1970, as `edits.updated_at` stores it.
    public var updatedAt: Int64
    /// History steps kept for the image (the history is capped, so a
    /// long-edited photo stops counting up at the cap).
    public var steps: Int

    public init(updatedAt: Int64, steps: Int) {
        self.updatedAt = updatedAt
        self.steps = steps
    }
}

/// One record's value under a sort key: a number or a piece of text.
/// Nil (no value) always sorts last, in either direction, as an unrated
/// photo does under Rating.
enum LibrarySortField: Equatable {
    case number(Double)
    case text(String)
}

extension LibrarySortKey {
    /// Where a key starts the first time it's chosen: the most recent, the
    /// most edited and the picks first, as a shoot is reviewed; everything
    /// else smallest or A first.
    var naturalAscending: Bool {
        switch self {
        case .captureTime, .modified, .rating, .editTime, .editCount, .pick: false
        default: true
        }
    }

    /// Whether this key reads the edit statistics rather than the record.
    public var readsEditStats: Bool { self == .editTime || self == .editCount }

    /// What this key sorts `record` by, for the keys `sorted(by:)` hands
    /// over here (not capture time, file name, rating, modified or Custom).
    func field(of record: ImageRecord, editStats: [Int64: LibraryEditStat]) -> LibrarySortField? {
        switch self {
        case .addedOrder:
            // Rows are numbered as the scan adds them.
            return record.id.map { .number(Double($0)) }
        case .editTime:
            return record.id.flatMap { editStats[$0] }.map { .number(Double($0.updatedAt)) }
        case .editCount:
            // An image with an edit but no kept history still counts as one.
            return record.id.flatMap { editStats[$0] }.map { .number(Double(max($0.steps, 1))) }
        case .pick:
            // Picked, then unflagged, then rejected (descending).
            return .number(Double(record.flag))
        case .labelText:
            return Self.text(record.label)
        case .labelColour:
            return Self.labelColourRank(record.label).map { .number(Double($0)) }
        case .fileExtension:
            return Self.text((record.sourceFileName as NSString).pathExtension.lowercased())
        case .fileType:
            return .text(Self.fileType(of: record))
        case .aspectRatio:
            return Self.aspectRatio(of: record).map { .number($0) }
        case .title:
            return Self.text(record.title)
        case .caption:
            return Self.text(record.caption)
        case .camera:
            return Self.text(record.camera)
        case .lens:
            return Self.text(record.lens)
        case .iso:
            return record.iso.flatMap { $0 > 0 ? .number(Double($0)) : nil }
        case .focalLength:
            return record.focal.flatMap { $0 > 0 && $0.isFinite ? .number($0) : nil }
        case .captureTime, .fileName, .rating, .modified, .custom:
            return nil
        }
    }

    private static func text(_ value: String?) -> LibrarySortField? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return .text(trimmed)
    }

    /// The five labels in Lightroom's order (red first), then any label
    /// another application wrote; no label has no rank.
    static func labelColourRank(_ label: String?) -> Int? {
        guard let text = label?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        guard let colour = ColorLabel(xmpLabel: text) else { return ColorLabel.allCases.count }
        return ColorLabel.allCases.firstIndex(of: colour)
    }

    /// The kind of file, as Lightroom's File Type sort groups them: every
    /// camera raw as "Raw", DNG on its own, and the picture formats by name.
    static func fileType(of record: ImageRecord) -> String {
        let ext = (record.sourceFileName as NSString).pathExtension.lowercased()
        switch ext {
        case "dng": return "DNG"
        case "jpg", "jpeg": return "JPEG"
        case "heic", "heif", "hif": return "HEIF"
        case "tif", "tiff": return "TIFF"
        default:
            if Catalog.rawExtensions.contains(ext) { return "Raw" }
            return ext.uppercased()
        }
    }

    /// Width over height as the photo shows in the grid: the camera's
    /// orientation and the user's quarter turns both swap the sides. Nil
    /// until the size is known. The crop isn't read.
    static func aspectRatio(of record: ImageRecord) -> Double? {
        guard let width = record.width, let height = record.height, width > 0, height > 0 else { return nil }
        // LibRaw's flip (5 and 6 turn a quarter) or an EXIF orientation
        // (5 to 8 do).
        let cameraTurned = [5, 6, 7, 8].contains(record.orientation ?? 0)
        let userTurned = record.userRotation % 2 != 0
        let w = Double(width), h = Double(height)
        return cameraTurned != userTurned ? h / w : w / h
    }
}

/// Orders two fields with nil last, then by path for stability.
func orderFields(_ x: LibrarySortField?, _ y: LibrarySortField?, _ a: ImageRecord, _ b: ImageRecord,
                 ascending: Bool) -> Bool {
    switch (x, y) {
    case (nil, nil): return a.relPath < b.relPath
    case (nil, _): return false
    case (_, nil): return true
    case let (.number(p)?, .number(q)?):
        if p == q { return a.relPath < b.relPath }
        return ascending ? p < q : p > q
    case let (.text(p)?, .text(q)?):
        let c = p.localizedStandardCompare(q)
        if c == .orderedSame { return a.relPath < b.relPath }
        return ascending ? c == .orderedAscending : c == .orderedDescending
    case (.number?, .text?): return true
    case (.text?, .number?): return false
    }
}
