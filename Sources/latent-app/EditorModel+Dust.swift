import AppKit
import Foundation
import simd
import PixelEngine
import RawCore

// Sensor dust in the editor (docs/Retouch.md §6): Find Spots, the dust
// tool's clicks, the Visualise Spots view, and dust maps.
extension EditorModel {
    // MARK: - The list

    var selectedDust: HealPatch? {
        guard let i = selectedDustIndex, i < parameters.dust.count else { return nil }
        return parameters.dust[i]
    }

    var hasSelectedDust: Bool { selectedDust != nil }

    /// Where dust maps are kept. Replaceable so tests write to a folder
    /// of their own rather than the user's Application Support.
    static var dustMapStore = DustMapStore()

    /// The detector's options as the panel has them.
    var dustOptions: DustDetector.Options {
        DustDetector.Options(sensitivity: dustSensitivity, size: dustSize)
    }

    /// The radius a dust shadow should have in this photo, from its
    /// aperture and the sensor's pitch; nil when the file doesn't say.
    var expectedDustRadius: Float? {
        session.flatMap { DustPhoto.expectedRadius(for: $0.file.summary) }
    }

    /// The radius the detector centres on: the expected one when the band
    /// holds it, else the band's middle. Tunes Visualise Spots too.
    var dustBandRadius: Float {
        let band = dustSize.sensorRadiusRange
        if let r = expectedDustRadius, band.contains(r) { return r }
        return dustSize.centreRadius
    }

    /// Visualise Spots for the display render: only the viewport, and
    /// not while Before is held, which shows the photo as it came.
    var dustVisualisation: SpotVisualisation? {
        guard visualiseSpots, hasImage, !showingBefore else { return nil }
        return SpotVisualisation(threshold: visualiseThreshold, radiusSensorPx: dustBandRadius)
    }

    // MARK: - Image changes

    /// Another image is about to open, or none: the analysis belongs to
    /// the old one, and the view settings start afresh.
    func dustImageWillChange() {
        dustAnalysis = nil
        dustToolActive = false
        selectedDustIndex = nil
        visualiseSpots = false
    }

    /// An image has opened: the band that holds the radius its aperture
    /// predicts, else Medium.
    func dustImageDidOpen() {
        dustSize = expectedDustRadius.map(DustSpotSize.band(holding:)) ?? .medium
    }

    /// The tool was disarmed: the analysis (about 72 MB at 24 MP) is only
    /// kept while the sensitivity and size controls can re-detect from it.
    func dustToolDidDisarm() {
        dustAnalysis = nil
    }

    // MARK: - Find Spots

    /// The analysis of the open image, made on the main actor as red-eye's
    /// and touch-up's renders are: the session is not Sendable and the
    /// editor renders it on the main actor whenever a slider moves or the
    /// view scrolls, so a render from another thread would share its
    /// texture pool and caches with those. One binned render, a readback
    /// and the map; nil with the failure in the status bar.
    private func dustAnalysisNow(_ what: String) -> DustDetector.Analysis? {
        guard let session, let pipeline, let gpu = gpuContext else { return nil }
        do {
            return try DustDetector.analyse(session: session, pipeline: pipeline, gpu: gpu, parameters: parameters)
        } catch {
            status = "\(what) failed: \(error)"
            return nil
        }
    }

    /// Looks for sensor dust in the photo on this Mac and heals each spot,
    /// replacing the spots found last time as one history step. The
    /// analysis is made on the main actor; only the detection runs off
    /// it, and its result is dropped if another image opened meanwhile.
    func findDustSpots() {
        guard let session, !findingDust else { return }
        // A slider moved a moment ago is saved as its own step first, so
        // Find Spots is a step of its own that Undo takes back alone.
        flushPendingSave()
        guard let analysis = dustAnalysisNow("Finding dust spots") else { return }
        findingDust = true
        status = "Looking for dust spots…"
        let options = dustOptions
        let expected = expectedDustRadius
        // The old list is replaced, so only the user's own patches and the
        // blemishes keep a blob from being healed twice.
        let existing = parameters.touchUp.activeBlemishes + parameters.heals
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let found = DustDetector.detect(analysis, options: options, expectedRadius: expected, existing: existing)
                // Only when nothing is left does it matter whether the
                // photo has no dust or its dust is already patched.
                let detected = found.isEmpty
                    ? DustDetector.detect(analysis, options: options, expectedRadius: expected, existing: []).count
                    : found.count
                return DustDetection(analysis: analysis, patches: found, detected: detected)
            }.value
            guard let self else { return }
            self.findingDust = false
            // The user may have moved to another image meanwhile.
            guard self.session === session else { return }
            self.dustAnalysis = result.analysis
            self.dustToolActive = true
            self.replaceDust(with: result.patches, detected: result.detected)
        }
    }

    /// Sensitivity or Spot Size moved while the tool is armed: the list is
    /// found again from the kept analysis, with no new render. One
    /// detection runs at a time; a control that moves meanwhile is looked
    /// at again once it ends, so a drag costs a couple of detections, not
    /// one per tick.
    func redetectDustIfArmed() {
        guard dustToolActive, hasImage, !findingDust else { return }
        // A memory warning drops the analysis (docs/Retouch.md §10) and
        // nothing rebuilds it in the middle of a shortage; the controls
        // say so rather than moving with no effect.
        guard dustAnalysis != nil else {
            status = "Click Find Spots to use the new Sensitivity or Spot Size"
            return
        }
        redetectDust()
    }

    private func redetectDust() {
        guard let session, let analysis = dustAnalysis else { return }
        let options = dustOptions
        let expected = expectedDustRadius
        let existing = parameters.touchUp.activeBlemishes + parameters.heals
        findingDust = true
        Task { @MainActor [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                DustDetector.detect(analysis, options: options, expectedRadius: expected, existing: existing)
            }.value
            guard let self else { return }
            self.findingDust = false
            guard self.session === session, self.dustToolActive, self.dustAnalysis != nil else { return }
            if self.dustOptions != options {
                self.redetectDust()
                return
            }
            // An ordinary parameter change: the debounced save makes one
            // history step of the whole drag.
            self.parameters.dust = found
            self.selectedDustIndex = nil
            self.status = SpokenText.dustFound(added: found.count, detected: found.count)
        }
    }

    /// Puts `found` in place of the list as one settled edit, saved and
    /// recorded at once, and says what was found.
    private func replaceDust(with found: [HealPatch], detected: Int) {
        // An edit made while the analysis ran is its own step too.
        flushPendingSave()
        parameters.dust = Array(found.prefix(HealPatch.maximumDustCount))
        selectedDustIndex = nil
        flushPendingSave()
        status = SpokenText.dustFound(added: found.count, detected: detected)
        Announcement.post(status)
    }

    // MARK: - The tool

    /// The ring under `p` (normalised sensor): within the ring plus a grab
    /// margin, since the rings are a few pixels across. The selected one
    /// first, then the most recent on top.
    func hitDustRing(_ p: SIMD2<Float>) -> Int? {
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let short = min(size.x, size.y)
        let grab = HealStrokeHandle.minimumGrabPixels / Float(max(viewport.zoom, 1e-6))
        var order = Array(parameters.dust.indices.reversed())
        if let s = selectedDustIndex, let k = order.firstIndex(of: s) { order.remove(at: k); order.insert(s, at: 0) }
        for i in order {
            let spot = parameters.dust[i]
            if simd_length((p - spot.target) * size) <= spot.radius * short + grab { return i }
        }
        return nil
    }

    /// A click with the dust tool armed: a ring removes that spot (a false
    /// one), the image adds a spot of the band's middle radius there. The
    /// click lands on the corrected image; the spot, like every heal
    /// patch, is on the raw grid, so it goes through the lens map. While
    /// a detection runs its list is about to replace this one, so the
    /// click waits rather than vanishing when the detection lands.
    func dustToolBegan(at screen: CGPoint) {
        guard hasImage else { return }
        guard !findingDust else {
            status = "Wait for the dust analysis to finish"
            return
        }
        let p = rawNormalized(sensorNormalized(screen))
        if let i = hitDustRing(p) {
            removeDust(at: i)
            return
        }
        addDustSpot(at: simd_clamp(p, SIMD2(0, 0), SIMD2(1, 1)))
    }

    /// Adds a spot at `p` (normalised sensor) sized for the band, with its
    /// source placed clear of every other patch; from the kept analysis
    /// when there is one, else by the gradient-free rule.
    func addDustSpot(at p: SIMD2<Float>) {
        guard parameters.dust.count < HealPatch.maximumDustCount else {
            status = "At most \(HealPatch.maximumDustCount) dust spots per image"
            return
        }
        let size = SIMD2(Float(sensorSize.width), Float(sensorSize.height))
        let short = min(size.x, size.y)
        let spot = DustSourcePlacer.Spot(centre: p * size, radius: DustPhoto.patchRadius(forBlobRadius: dustSize.centreRadius))
        let others = (parameters.dust + parameters.touchUp.activeBlemishes + parameters.heals).flatMap { patch in
            patch.pathPoints().map { DustSourcePlacer.Spot(centre: $0 * size, radius: patch.radius * short) }
        }
        guard let source = DustSourcePlacer.place(spot, avoiding: others, sensorSize: size, analysis: dustAnalysis) else {
            status = "No clear patch of image near there to heal from"
            return
        }
        parameters.dust.append(HealPatch(target: p, source: source / size, radius: spot.radius / short,
                                         feather: 0.5, mode: .heal))
        selectedDustIndex = parameters.dust.count - 1
    }

    func removeDust(at i: Int) {
        guard i < parameters.dust.count else { return }
        parameters.dust.remove(at: i)
        selectedDustIndex = parameters.dust.isEmpty ? nil : min(i, parameters.dust.count - 1)
    }

    func deleteSelectedDust() {
        guard let i = selectedDustIndex else { return }
        guard !findingDust else {
            status = "Wait for the dust analysis to finish"
            return
        }
        removeDust(at: i)
    }

    func clearDust() {
        parameters.dust = []
        selectedDustIndex = nil
    }

    // MARK: - Dust maps

    /// Saves the current list as a dust map for this camera, so the same
    /// spots can be looked for in other photos (Photo › Remove Dust…).
    func saveDustMap() {
        guard let session else { return }
        guard !parameters.dust.isEmpty else {
            status = "No dust spots to save"
            return
        }
        let summary = session.file.summary
        let patches = parameters.dust
        let name = sourceURL?.lastPathComponent ?? imageTitle ?? ""
        let options = dustOptions
        withDustAnalysis(status: "Measuring the dust spots…", work: { analysis in
            DustDetector.mapSpots(from: patches, analysis: analysis)
        }, finish: { [weak self] spots in
            guard let self else { return }
            let map = DustMap(camera: DustPhoto.camera(for: summary),
                              sensorSize: SIMD2(summary.rawWidth, summary.rawHeight),
                              referenceName: name, referenceCaptureDate: DustPhoto.captureDate(of: summary),
                              aperture: summary.aperture > 0 ? summary.aperture : nil,
                              options: options, spots: spots)
            do {
                try Self.dustMapStore.add(map)
                self.status = "Saved dust map “\(map.title)”"
            } catch {
                self.reportFailure("Saving the dust map", error)
            }
        })
    }

    /// Looks for a map's spots in this photo and heals the ones that are
    /// there, keeping every spot and patch already in the edit (the
    /// Remove Dust sheet's in-memory path, and From dust map…).
    func applyDustMap(_ map: DustMap, options: DustDetector.Options) {
        guard let session else { return }
        let summary = session.file.summary
        guard map.camera == DustPhoto.camera(for: summary),
              map.sensorSize == SIMD2(summary.rawWidth, summary.rawHeight) else {
            status = "The dust map is for a \(map.camera), not this photo’s camera"
            Announcement.post(status)
            return
        }
        flushPendingSave()
        let existing = parameters.dust + parameters.touchUp.activeBlemishes + parameters.heals
        withDustAnalysis(status: "Looking for the map’s dust spots…", work: { analysis in
            let found = DustDetector.verify(map.spots, in: analysis, options: options, existing: existing)
            let detected = found.isEmpty
                ? DustDetector.verify(map.spots, in: analysis, options: options, existing: []).count
                : found.count
            return DustDetection(analysis: analysis, patches: found, detected: detected)
        }, finish: { [weak self] result in
            guard let self else { return }
            self.dustToolActive = true
            if !result.patches.isEmpty {
                self.flushPendingSave()
                self.parameters.dust = Array((self.parameters.dust + result.patches).prefix(HealPatch.maximumDustCount))
                self.selectedDustIndex = nil
                self.flushPendingSave()
            }
            self.status = SpokenText.dustFound(added: result.patches.count, detected: result.detected)
            Announcement.post(self.status)
        })
    }

    /// Runs `work` on the analysis off the main thread, analysing the
    /// photo first (on the main actor, as Find Spots does) when none is
    /// kept, then `finish` on the main actor with the result, unless
    /// another image opened meanwhile. The analysis is kept afterwards
    /// only while the tool is armed.
    private func withDustAnalysis<T: Sendable>(status: String,
                                               work: @escaping @Sendable (DustDetector.Analysis) -> T,
                                               finish: @escaping @MainActor (T) -> Void) {
        guard let session, !findingDust else { return }
        let analysis: DustDetector.Analysis
        if let kept = dustAnalysis {
            analysis = kept
        } else {
            self.status = status
            guard let made = dustAnalysisNow("Analysing the photo for dust") else { return }
            analysis = made
        }
        findingDust = true
        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { work(analysis) }.value
            guard let self else { return }
            self.findingDust = false
            guard self.session === session else { return }
            finish(result)
            if self.dustToolActive { self.dustAnalysis = analysis }
        }
    }
}

/// What a detection made: the analysis it ran on, the patches to add, and
/// how many blobs it saw before those under existing patches were dropped.
private struct DustDetection: Sendable {
    let analysis: DustDetector.Analysis
    let patches: [HealPatch]
    let detected: Int
}

/// What the editor and the Remove Dust job read off a photo for dust.
enum DustPhoto {
    /// The camera string dust maps are keyed by: `ImageRecord.camera`,
    /// "Make Model", built as the catalog builds it.
    static func camera(for summary: RawSummary) -> String {
        [summary.cameraMake, summary.cameraModel].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The radius a dust shadow should have in this photo: from its
    /// aperture and the sensor's crop factor, the file's when it records
    /// one, else the Lensfun database's for the camera; nil when neither
    /// is known.
    static func expectedRadius(for summary: RawSummary) -> Float? {
        guard summary.aperture > 0 else { return nil }
        var crop = summary.lens.cropFactor
        if crop <= 0 {
            crop = MergePanoPrepKernels.Lens.cameraCropFactor(make: summary.cameraMake, model: summary.cameraModel) ?? 0
        }
        guard crop > 0 else { return nil }
        return DustDetector.expectedRadius(aperture: summary.aperture, cropFactor: crop, rawWidth: summary.rawWidth)
    }

    /// The patch that heals a blob of `radius` sensor px, as the detector
    /// sizes one: half again as far plus a pixel each side.
    static func patchRadius(forBlobRadius radius: Float) -> Float {
        1.5 * radius + 2
    }

    static func captureDate(of summary: RawSummary) -> Date? {
        summary.captureTime.timeIntervalSince1970 > 0 ? summary.captureTime : nil
    }
}

extension DustSpotSize {
    /// The middle of the band, in sensor px: a click-to-add spot's size.
    var centreRadius: Float {
        (sensorRadiusRange.lowerBound + sensorRadiusRange.upperBound) / 2
    }

    /// The band to look in for a shadow of `radius`: the one whose range
    /// holds it, Medium when two do, and the nearest end past the bands.
    static func band(holding radius: Float) -> DustSpotSize {
        if DustSpotSize.medium.sensorRadiusRange.contains(radius) { return .medium }
        if DustSpotSize.small.sensorRadiusRange.contains(radius) { return .small }
        if DustSpotSize.large.sensorRadiusRange.contains(radius) { return .large }
        return radius < DustSpotSize.medium.sensorRadiusRange.lowerBound ? .small : .large
    }
}
