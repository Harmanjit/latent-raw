import SwiftUI
import AppKit
import Catalog
import RawCore

/// The shooting values the Ranges popover filters on.
enum FilterRangeField: String, CaseIterable, Identifiable {
    case iso, focal, aperture, shutter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iso: "ISO"
        case .focal: "Focal length"
        case .aperture: "Aperture"
        case .shutter: "Exposure time"
        }
    }

    var keyPath: WritableKeyPath<LibraryFilter, ClosedRange<Double>?> {
        switch self {
        case .iso: \.isoRange
        case .focal: \.focalRange
        case .aperture: \.apertureRange
        case .shutter: \.shutterRange
        }
    }

    func value(of record: ImageRecord) -> Double? {
        switch self {
        case .iso: record.iso.map(Double.init)
        case .focal: record.focal
        case .aperture: record.aperture
        case .shutter: record.shutter
        }
    }

    /// "ISO 800", "35 mm", "f/2.8", "1/250 s".
    func format(_ value: Double) -> String {
        switch self {
        case .iso: return "\(SaneExposure.wholeNumber(value))"
        case .focal: return "\(SaneExposure.wholeNumber(value)) mm"
        case .aperture: return String(format: "f/%.1f", value)
        case .shutter:
            if value >= 1 { return String(format: value < 10 ? "%.1f s" : "%.0f s", value) }
            return "1/\(SaneExposure.wholeNumber(1 / value)) s"
        }
    }
}

/// The filter bar's Ranges button: ISO, focal length, aperture and
/// exposure time, each a histogram of the folder (or collection) with a
/// two-thumb range under it. Clear Filters (⇧⌘L) clears these too.
struct RangesFilterButton: View {
    @ObservedObject var library: Library
    @State private var showing = false

    private var activeCount: Int {
        FilterRangeField.allCases.filter { library.filter[keyPath: $0.keyPath] != nil }.count
    }

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Text(activeCount == 0 ? "Ranges" : "Ranges (\(activeCount))")
                .lineLimit(1)
        }
        .help("Show only photos whose ISO, focal length, aperture or exposure time is in a range")
        .accessibilityLabel("Ranges")
        .accessibilityValue(activeCount == 0 ? "Any" : "\(activeCount) set")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            RangesFilterPopover(library: library)
        }
        #if DEBUG
        .snapshotHook(.rangesPopover, $showing)
        #endif
    }
}

struct RangesFilterPopover: View {
    @ObservedObject var library: Library
    /// Worked out when the popover opens, from the photos before the filter
    /// bar, so narrowing one range doesn't empty the others' histograms.
    @State private var histograms: [FilterRangeField: RangeHistogram] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(FilterRangeField.allCases) { field in
                row(field)
            }
            HStack {
                Text("Photos without the value are hidden while its range is set.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Clear Ranges") {
                    for field in FilterRangeField.allCases { library.filter[keyPath: field.keyPath] = nil }
                }
                .disabled(FilterRangeField.allCases.allSatisfy { library.filter[keyPath: $0.keyPath] == nil })
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 320)
        .onAppear { computeHistograms() }
    }

    private func computeHistograms() {
        let records = library.imagesInScope
        var next: [FilterRangeField: RangeHistogram] = [:]
        for field in FilterRangeField.allCases {
            next[field] = RangeHistogram(values: records.compactMap(field.value(of:)))
        }
        histograms = next
    }

    @ViewBuilder
    private func row(_ field: FilterRangeField) -> some View {
        let histogram = histograms[field] ?? RangeHistogram(values: [])
        let range = library.filter[keyPath: field.keyPath]
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(field.title).font(.caption.weight(.semibold))
                Spacer()
                Text(summary(field, histogram: histogram, range: range))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if range != nil {
                    Button {
                        library.filter[keyPath: field.keyPath] = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear the \(field.title.lowercased()) range")
                    .accessibilityLabel("Clear \(field.title)")
                }
            }
            if histogram.isEmpty {
                Text("No photo here records this.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                RangeHistogramSlider(histogram: histogram,
                                     buckets: Binding(
                                        get: { histogram.buckets(for: library.filter[keyPath: field.keyPath]) },
                                        set: { library.filter[keyPath: field.keyPath] = histogram.range(buckets: $0) }))
                    .frame(height: 44)
                    .accessibilityLabel(field.title)
                    .accessibilityValue(summary(field, histogram: histogram, range: range))
            }
        }
    }

    private func summary(_ field: FilterRangeField, histogram: RangeHistogram, range: ClosedRange<Double>?) -> String {
        if let range { return "\(field.format(range.lowerBound)) – \(field.format(range.upperBound))" }
        if histogram.isEmpty { return "Any" }
        return "Any (\(field.format(histogram.lower)) – \(field.format(histogram.upper)))"
    }
}

/// Bars for the bucket counts and two thumbs under them. Dragging moves
/// whichever thumb is nearer where the drag starts; the bars between the
/// thumbs are drawn in the accent colour. A click on a bar (no drag) sets
/// the range to that bar's bucket, Shift-click stretches it to the bar,
/// and a double-click clears it (`RangeBarClick`).
struct RangeHistogramSlider: View {
    let histogram: RangeHistogram
    @Binding var buckets: ClosedRange<Int>
    @State private var draggingUpper: Bool?
    /// The bar clicked last, which a Shift-click stretches from.
    @State private var clickAnchor: Int?

    private static let thumb: CGFloat = 10
    /// The buckets `RangeHistogram` makes when the values differ.
    private static let fullBucketCount = 24
    /// How far the pointer may move on a bar before a press counts as a drag.
    private static let clickSlop: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let n = max(histogram.bucketCount, 1)
            let barArea = geometry.size.height - Self.thumb - 2
            let peak = Double(max(histogram.counts.max() ?? 1, 1))
            let step = width / CGFloat(n)
            // No wider than one of a full histogram's bars, so a single
            // bucket (every photo the same value) is a bar, not a slab.
            let barWidth = min(max(1, step - 1), max(1, width / CGFloat(Self.fullBucketCount) - 1))
            ZStack(alignment: .topLeading) {
                ForEach(Array(histogram.counts.enumerated()), id: \.offset) { index, count in
                    let inside = buckets.contains(index)
                    // Square root, so a single odd photo still shows beside a hundred.
                    let height = count == 0 ? 0 : max(1.5, barArea * CGFloat((Double(count) / peak).squareRoot()))
                    Rectangle()
                        .fill(inside ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: barWidth, height: height)
                        .offset(x: CGFloat(index) * step + (step - barWidth) / 2, y: barArea - height)
                }
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: width, height: 1)
                    .offset(y: barArea)
                thumbView.offset(x: CGFloat(buckets.lowerBound) * step - Self.thumb / 2, y: barArea + 2)
                thumbView.offset(x: CGFloat(buckets.upperBound + 1) * step - Self.thumb / 2, y: barArea + 2)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                // A press on the bars may be a click: it becomes a drag
                // only once the pointer has moved. On the thumbs' strip
                // dragging starts at once, as it always has.
                let onBars = drag.startLocation.y < barArea
                let moved = max(abs(drag.translation.width), abs(drag.translation.height))
                if onBars, draggingUpper == nil, moved < Self.clickSlop { return }
                let position = Int((drag.location.x / max(step, 1)).rounded())
                if draggingUpper == nil {
                    let start = drag.startLocation.x / max(step, 1)
                    let lowerDistance = abs(start - CGFloat(buckets.lowerBound))
                    let upperDistance = abs(start - CGFloat(buckets.upperBound + 1))
                    draggingUpper = upperDistance < lowerDistance
                }
                if draggingUpper == true {
                    let upper = min(max(position - 1, buckets.lowerBound), n - 1)
                    if upper != buckets.upperBound { buckets = buckets.lowerBound...upper }
                } else {
                    let lower = min(max(position, 0), buckets.upperBound)
                    if lower != buckets.lowerBound { buckets = lower...buckets.upperBound }
                }
            }.onEnded { drag in
                defer { draggingUpper = nil }
                // Never turned into a drag, and started on the bars: a click.
                guard draggingUpper == nil, drag.startLocation.y < barArea else { return }
                let event = NSApp.currentEvent
                let result = RangeBarClick.apply(index: Int(drag.startLocation.x / max(step, 1)),
                                                 clickCount: event?.clickCount ?? 1,
                                                 extending: event?.modifierFlags.contains(.shift) ?? false,
                                                 current: buckets, anchor: clickAnchor, bucketCount: n)
                clickAnchor = result.anchor
                if result.buckets != buckets { buckets = result.buckets }
            })
        }
        .help("Click a bar to show just its photos, Shift-click to extend, double-click to clear; drag to set a range")
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            // VoiceOver narrows or widens from the top, one bucket at a time.
            let n = max(histogram.bucketCount, 1)
            switch direction {
            case .increment: buckets = buckets.lowerBound...min(buckets.upperBound + 1, n - 1)
            case .decrement: buckets = buckets.lowerBound...max(buckets.upperBound - 1, buckets.lowerBound)
            @unknown default: break
            }
        }
    }

    private var thumbView: some View {
        Circle()
            .fill(Color(nsColor: .controlColor))
            .overlay(Circle().strokeBorder(Color.secondary, lineWidth: 1))
            .frame(width: Self.thumb, height: Self.thumb)
    }
}
