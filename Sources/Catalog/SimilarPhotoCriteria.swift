import Foundation

/// "Similar to This Photo": the filter bar set to one photo's camera body,
/// its lens and capture times within a day of it, each part switched on
/// or off in the filter bar's Similar popover to widen the search.
///
/// The criteria only write the filter's existing `camera`, `lens` and
/// `captureDateRange` fields, so what the grid shows is an ordinary filter
/// (presets, Clear Filters and the rest treat it as such). A part the
/// photo has no value for (no lens recorded, no capture time) can't be
/// switched on.
public struct SimilarPhotoCriteria: Equatable, Sendable {
    /// How far either side of the photo's capture time the date part
    /// reaches: one day.
    public static let dateWindow: TimeInterval = 86_400

    /// The reference photo's file name, for the popover's title.
    public let photoName: String
    public let camera: String?
    public let lens: String?
    public let captureTime: Date?

    /// Whether each part narrows the filter now. Always false for a part
    /// the photo has no value for.
    public var matchesCamera: Bool { didSet { if camera == nil { matchesCamera = false } } }
    public var matchesLens: Bool { didSet { if lens == nil { matchesLens = false } } }
    public var matchesDate: Bool { didSet { if captureTime == nil { matchesDate = false } } }

    /// Every part the photo has a value for, switched on.
    public init(record: ImageRecord) {
        photoName = record.fileName
        camera = Self.cleaned(record.camera)
        lens = Self.cleaned(record.lens)
        captureTime = record.captureTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        matchesCamera = camera != nil
        matchesLens = lens != nil
        matchesDate = captureTime != nil
    }

    /// The photo's capture time ± `dateWindow`, nil without one.
    public var dateRange: ClosedRange<Date>? {
        captureTime.map { $0.addingTimeInterval(-Self.dateWindow)...$0.addingTimeInterval(Self.dateWindow) }
    }

    /// Whether the photo has anything to match on at all.
    public var hasAnyPart: Bool { camera != nil || lens != nil || captureTime != nil }

    /// `base` with camera, lens and capture date set from the parts that
    /// are on, and cleared for the parts that are off. Everything else in
    /// `base` is kept.
    public func applied(to base: LibraryFilter) -> LibraryFilter {
        var filter = base
        filter.camera = matchesCamera ? camera : nil
        filter.lens = matchesLens ? lens : nil
        filter.captureDateRange = matchesDate ? dateRange : nil
        return filter
    }

    /// Whether `filter` still holds what these criteria put there. Once the
    /// user picks another camera, lens or date in the bar (or clears it),
    /// the filter is theirs again and the Similar chip goes.
    public func isReflected(in filter: LibraryFilter) -> Bool {
        filter.camera == (matchesCamera ? camera : nil)
            && filter.lens == (matchesLens ? lens : nil)
            && filter.captureDateRange == (matchesDate ? dateRange : nil)
    }

    /// The filter matches camera and lens exactly, so the record's own
    /// spelling is kept; only an empty string counts as no value.
    private static func cleaned(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
