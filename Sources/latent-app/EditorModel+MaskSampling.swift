import AppKit
import simd
import PixelEngine

/// What a press with a range eyedropper does to the samples taken so far.
enum MaskSampleMode: Equatable {
    /// A plain press: start over from this one sample (the eyedropper's
    /// behaviour before multi-sampling).
    case replace
    /// Shift: add this sample; the range grows to cover it.
    case add
    /// Option: take away the sample nearest the press.
    case remove

    /// The mode for the modifier keys held now. Option is passed in, as
    /// the view reports it with the press; Shift is read from the event
    /// state, which at a mouse-down is the press's own.
    @MainActor static func current(optionHeld: Bool) -> MaskSampleMode {
        if optionHeld { return .remove }
        return NSEvent.modifierFlags.contains(.shift) ? .add : .replace
    }
}

/// The samples behind the selected range, kept for the session only: the
/// edit stores just the band they make.
struct RangeSamples: Equatable {
    /// The mask and range component (nil: the mask's own Luminance range)
    /// the samples belong to.
    var local: UUID
    var component: UUID?
    var set: MaskRangeSampleSet
    /// The band the samples last wrote. If the range no longer has it (a
    /// slider moved, Undo), Shift-click grows the band as it is now.
    var band: MaskRangeBand
}

/// Where each Colour Range sample of one component was clicked, in order;
/// nil for a sample whose position this session never saw (one saved in
/// the edit before it was opened).
struct ColourSamplePositions: Equatable {
    var component: UUID
    var points: [SIMD2<Float>?]
}

/// Session state for the eyedroppers' sample points (`EditorModel.maskSampling`).
struct MaskSamplingState: Equatable {
    /// The mode of the press in progress, read when it ends.
    var pressMode: MaskSampleMode = .replace
    var range: RangeSamples?
    var colour: ColourSamplePositions?
}

extension EditorModel {
    // MARK: - Pick Range samples

    /// The current range target as a key: the selected mask's id and the
    /// range component's (nil for the mask's own Luminance range).
    private var rangeSampleKey: (local: UUID, component: UUID?)? {
        guard let target = selectedRangeTarget, let local = selectedLocal else { return nil }
        return (local.id, target.component)
    }

    /// The samples kept for the selected range, if they are still its own.
    var currentRangeSamples: RangeSamples? {
        guard let key = rangeSampleKey, let kept = maskSampling.range,
              kept.local == key.local, kept.component == key.component else { return nil }
        return kept
    }

    /// After a plain press set the band: the one sample it was.
    func recordReplacingRangeSample(values: [Float], box: CGRect, band: MaskRangeBand) {
        guard let key = rangeSampleKey else { return }
        let centre = SIMD2(Float(box.midX), Float(box.midY))
        let sample = values.count == 1 ? MaskRangeSample.point(values[0], at: centre)
                                       : MaskRangeSample.region(values, at: centre)
        maskSampling.range = RangeSamples(local: key.local, component: key.component,
                                          set: MaskRangeSampleSet(samples: sample.map { [$0] } ?? []), band: band)
    }

    /// Shift: adds the press as a sample and widens the band to cover
    /// every sample; Option: takes away the sample nearest the press and
    /// fits the band to those left. The eyedropper stays armed.
    func finishRangeSample(_ box: CGRect, mode: MaskSampleMode) {
        guard let key = rangeSampleKey, let current = selectedRangeBand else { return }
        let centre = SIMD2(Float(box.midX), Float(box.midY))
        var kept = currentRangeSamples
        // A band changed since the samples wrote it (a slider, Undo) is the
        // new starting point for Shift; Option has nothing left to remove.
        if kept?.band != current { kept = nil }
        switch mode {
        case .replace:
            return
        case .add:
            guard let values = rangeSampleValues(in: box),
                  let sample = values.count == 1 ? MaskRangeSample.point(values[0], at: centre)
                                                 : MaskRangeSample.region(values, at: centre) else { return }
            var set = kept?.set ?? MaskRangeSampleSet(base: current)
            set.samples.append(sample)
            apply(set, key: key, current: current)
            if let band = selectedRangeBand {
                status = String(format: "Range sample %d added: %.2f to %.2f", set.samples.count, band.low, band.high)
            }
        case .remove:
            guard var set = kept?.set, set.removeNearest(to: centre, aspect: sensorSizeVector) != nil else {
                status = "No range samples to remove"
                return
            }
            apply(set, key: key, current: current)
            if let band = selectedRangeBand {
                status = String(format: "Range sample removed: %.2f to %.2f", band.low, band.high)
            }
        }
    }

    /// Writes the band `set` makes (when it makes one) and keeps the set.
    private func apply(_ set: MaskRangeSampleSet, key: (local: UUID, component: UUID?), current: MaskRangeBand) {
        let band = set.band(keepingFeathersOf: current) ?? current
        if band != current { setSelectedRangeBand { _ in band } }
        maskSampling.range = RangeSamples(local: key.local, component: key.component, set: set,
                                          band: selectedRangeBand ?? band)
    }

    // MARK: - Colour Range sample points

    /// Remembers where a Colour Range sample was clicked. `count` is the
    /// component's sample count before the click; `droppedLast` whether
    /// the click replaced the last sample (the sixth replaces the fifth).
    func recordColourSamplePosition(_ point: SIMD2<Float>, component: UUID, countBefore count: Int, droppedLast: Bool) {
        var points = maskSampling.colour?.component == component ? maskSampling.colour!.points : []
        if points.count != count { points = Array(repeating: nil, count: count) }
        if droppedLast, !points.isEmpty { points.removeLast() }
        points.append(point)
        maskSampling.colour = ColourSamplePositions(component: component, points: points)
    }

    /// Option-click with the Colour Range eyedropper: takes away the
    /// sample clicked nearest `point` when positions are known, otherwise
    /// the sample nearest in colour to the pixel under it.
    func removeColourSample(near point: SIMD2<Float>) {
        guard let i = selectedLocalIndex, i < parameters.locals.count,
              let id = selectedMaskComponentID,
              let c = parameters.locals[i].components.firstIndex(where: { $0.id == id }),
              case .colour(var range) = parameters.locals[i].components[c].source else { return }
        guard !range.samples.isEmpty else { status = "No colour samples to remove"; return }
        var points = maskSampling.colour?.component == id ? maskSampling.colour!.points : []
        if points.count != range.samples.count { points = Array(repeating: nil, count: range.samples.count) }
        let aspect = sensorSizeVector
        let known = points.indices.filter { points[$0] != nil }
        let index: Int?
        if !known.isEmpty {
            index = known.min { simd_length_squared((points[$0]! - point) * aspect)
                                < simd_length_squared((points[$1]! - point) * aspect) }
        } else if let working = workingColour(at: point) {
            index = range.nearestSampleIndex(to: ColourRange.sample(working: working, contrast: parameters.contrast,
                                                                    greyPoint: parameters.greyPoint,
                                                                    toneRanges: parameters.toneRanges))
        } else {
            index = nil
        }
        guard let index else { return }
        range.samples.remove(at: index)
        points.remove(at: index)
        parameters.locals[i].components[c].source = .colour(range)
        maskSampling.colour = ColourSamplePositions(component: id, points: points)
        status = "Colour sample removed; \(range.samples.count) left"
    }

    // MARK: - Drawing

    /// The sample points to draw on the image: those of the selected
    /// range while Pick Range is armed, or of the selected Colour Range
    /// while its eyedropper is.
    var maskSamplePoints: [SIMD2<Float>] {
        switch maskTool {
        case .lumaSample:
            return currentRangeSamples?.set.samples.map(\.position) ?? []
        case .colourSample:
            guard let id = selectedMaskComponentID, let kept = maskSampling.colour, kept.component == id,
                  case .colour(let range)? = selectedMaskComponent?.source,
                  kept.points.count == range.samples.count else { return [] }
            return kept.points.compactMap { $0 }
        default:
            return []
        }
    }
}
