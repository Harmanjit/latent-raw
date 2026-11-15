import Foundation

/// A mini histogram of one shooting value (ISO, focal length, aperture,
/// exposure time) across a list of photos, for the filter bar's Ranges
/// popover: bucket counts, and the mapping between buckets and the value
/// range a two-thumb slider over them stands for. Plain numbers, so it is
/// tested without views.
public struct RangeHistogram: Equatable, Sendable {
    /// The smallest and largest value present.
    public let lower: Double
    public let upper: Double
    /// Photos per bucket, from `lower` to `upper`.
    public let counts: [Int]
    /// Buckets are even steps of the logarithm (ISO, apertures and
    /// exposure times double; focal lengths are judged by ratio too).
    public let logarithmic: Bool

    /// Buckets over `values` (non-positive ones are left out when the
    /// scale is logarithmic). Empty `counts` when there are no values.
    public init(values: [Double], bucketCount: Int = 24, logarithmic: Bool = true) {
        let usable = values.filter { $0.isFinite && (!logarithmic || $0 > 0) }
        self.logarithmic = logarithmic
        guard let low = usable.min(), let high = usable.max(), bucketCount > 0 else {
            lower = 0; upper = 0; counts = []
            return
        }
        lower = low
        upper = high
        // One value only: a single bucket holds everything.
        let n = high > low ? bucketCount : 1
        var counts = [Int](repeating: 0, count: n)
        let a = logarithmic ? log(low) : low, b = logarithmic ? log(high) : high
        for value in usable {
            let x = logarithmic ? log(value) : value
            let index = b > a ? Int(((x - a) / (b - a) * Double(n)).rounded(.down)) : 0
            counts[min(max(index, 0), n - 1)] += 1
        }
        self.counts = counts
    }

    public var isEmpty: Bool { counts.isEmpty }
    public var bucketCount: Int { counts.count }

    /// The value at the edge before bucket `index` (0...bucketCount).
    public func edge(_ index: Int) -> Double {
        guard bucketCount > 0 else { return lower }
        if index <= 0 { return lower }
        if index >= bucketCount { return upper }
        let t = Double(index) / Double(bucketCount)
        if logarithmic { return exp(log(lower) + (log(upper) - log(lower)) * t) }
        return lower + (upper - lower) * t
    }

    /// The value range buckets `first...last` cover, edges included; nil
    /// when that is every bucket (no constraint).
    public func range(buckets: ClosedRange<Int>) -> ClosedRange<Double>? {
        guard bucketCount > 0 else { return nil }
        let first = min(max(buckets.lowerBound, 0), bucketCount - 1)
        let last = min(max(buckets.upperBound, first), bucketCount - 1)
        if first == 0, last == bucketCount - 1 { return nil }
        return edge(first)...edge(last + 1)
    }

    /// The buckets a stored range covers, for putting the thumbs back;
    /// every bucket for nil.
    public func buckets(for range: ClosedRange<Double>?) -> ClosedRange<Int> {
        guard bucketCount > 0 else { return 0...0 }
        guard let range else { return 0...(bucketCount - 1) }
        let first = (0..<bucketCount).first { edge($0 + 1) > range.lowerBound } ?? 0
        let last = (0..<bucketCount).last { edge($0) < range.upperBound } ?? (bucketCount - 1)
        return first...max(first, last)
    }
}

/// The Date popover's quick ranges.
public enum CaptureDateQuickRange: String, CaseIterable, Sendable {
    case today, last7Days, thisMonth, thisYear

    public var title: String {
        switch self {
        case .today: "Today"
        case .last7Days: "Last 7 Days"
        case .thisMonth: "This Month"
        case .thisYear: "This Year"
        }
    }

    /// From the start of the first day to the end of today.
    public func range(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        let end = CaptureDateQuickRange.endOfDay(now, calendar: calendar)
        let start: Date
        switch self {
        case .today:
            start = calendar.startOfDay(for: now)
        case .last7Days:
            start = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        case .thisMonth:
            start = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        case .thisYear:
            start = calendar.dateInterval(of: .year, for: now)?.start ?? calendar.startOfDay(for: now)
        }
        return start...end
    }

    /// The whole days from `from` to `to`, whichever order they come in.
    public static func days(from: Date, to: Date, calendar: Calendar = .current) -> ClosedRange<Date> {
        let a = min(from, to), b = max(from, to)
        return calendar.startOfDay(for: a)...endOfDay(b, calendar: calendar)
    }

    static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        let start = calendar.startOfDay(for: date)
        let next = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return next.addingTimeInterval(-0.001)
    }
}

/// What a click on one bar of a Ranges histogram does to the selected
/// buckets: a plain click selects just that bar's bucket, a Shift-click
/// stretches the selection to it (from the bar clicked last, as Shift
/// extends a list selection), and a double-click clears the range.
/// Dragging the thumbs is unchanged; this is only for clicks on the bars.
public enum RangeBarClick {
    /// The buckets after the click, and the bucket a later Shift-click
    /// stretches from (nil once the range is cleared).
    ///
    /// - Parameters:
    ///   - index: the bucket clicked (clamped into the histogram).
    ///   - clickCount: 2 or more for a double-click.
    ///   - extending: Shift was held.
    ///   - current: the buckets selected now; every bucket when unconstrained.
    ///   - anchor: the bucket clicked last, if any. Ignored when it is no
    ///     longer inside `current` (the range was changed some other way).
    public static func apply(index: Int, clickCount: Int, extending: Bool, current: ClosedRange<Int>,
                             anchor: Int?, bucketCount: Int) -> (buckets: ClosedRange<Int>, anchor: Int?) {
        guard bucketCount > 0 else { return (0...0, nil) }
        let all = 0...(bucketCount - 1)
        if clickCount >= 2 { return (all, nil) }
        let index = min(max(index, 0), bucketCount - 1)
        let constrained = current != all
        if extending, constrained {
            if let anchor, current.contains(anchor) {
                return (min(anchor, index)...max(anchor, index), anchor)
            }
            // No bar clicked yet: stretch whichever end is nearer, keep the other.
            let lower = min(current.lowerBound, index), upper = max(current.upperBound, index)
            let kept = index < current.lowerBound ? current.upperBound : current.lowerBound
            return (lower...upper, kept)
        }
        return (index...index, index)
    }
}
