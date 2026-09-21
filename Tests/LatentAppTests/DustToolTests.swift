import XCTest
import AppKit
import simd
import Catalog
import MergeKit
import PixelEngine
@testable import latent_app

// The dust tool in the editor (docs/Retouch.md §6, §11): Find Spots as a
// history step of its own, the rings' clicks, Clear, dust maps in and
// out. The photo is a synthetic "dirty sensor" DNG (`DustDNG`), so the
// real analysis and detector run on the GPU and find spots that are
// known to be there.

/// A plain grey sky with a gentle gradient, faint noise and soft dark
/// discs where dust would be, as a float LinearRaw DNG that the catalog
/// and the editor open like any raw.
enum DustDNG {
    struct Spot: Equatable {
        /// Sensor px.
        let centre: SIMD2<Float>
        let radius: Float
    }

    static let width = 800
    static let height = 600
    static let sensorSize = SIMD2<Float>(Float(width), Float(height))

    /// Nine spots well apart, 10 px across the sensor: 5 px on the binned
    /// analysis map, inside the Medium band.
    static let spots: [Spot] = [
        [120, 100], [400, 90], [680, 130], [150, 300], [420, 320], [700, 290], [110, 500], [390, 520], [660, 480],
    ].map { Spot(centre: $0, radius: 10) }

    /// The spot a patch sits on, when its target is within the spot.
    static func spot(under patch: HealPatch, among spots: [Spot] = spots) -> Spot? {
        let target = patch.target * sensorSize
        return spots.first { simd_distance($0.centre, target) <= $0.radius }
    }

    @discardableResult
    static func write(to url: URL, spots: [Spot] = spots, make: String = "Nikon", model: String = "D750",
                      seed: UInt32 = 1) throws -> MergeDNGWriteResult {
        var pixels = [Float16](repeating: 0, count: width * height * 3)
        var state = seed
        for y in 0..<height {
            for x in 0..<width {
                // A sky brightening a tenth across the frame, with noise of
                // about a percent so the detector's noise estimate is real.
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise = (Float(state >> 8) / Float(1 << 24) - 0.5) * 0.008
                var value = 0.5 * (1 + 0.1 * Float(x) / Float(width)) + noise
                for spot in spots {
                    let d = simd_distance(spot.centre, SIMD2(Float(x) + 0.5, Float(y) + 0.5))
                    guard d < 2 * spot.radius else { continue }
                    // A flat-topped disc with a soft edge: about the spot's
                    // radius at half depth, as a dust shadow is.
                    value *= 1 - 0.3 * exp(-pow(d / spot.radius, 4))
                }
                let i = (y * width + x) * 3
                pixels[i] = Float16(value); pixels[i + 1] = Float16(value); pixels[i + 2] = Float16(value)
            }
        }
        let metadata = MergeDNGMetadata(
            make: make, model: model,
            colorMatrix1: try MergeDNGMetadata.colorMatrix(fromCamXYZ: [0.9020, -0.2890, -0.0715, -0.4535, 1.2436,
                                                                         0.2348, -0.0934, 0.1919, 0.7086]),
            asShotNeutral: try MergeDNGMetadata.asShotNeutral(fromCameraMultipliers: [2.078125, 1, 1.207031]),
            software: "Latent tests", captureDate: Date(timeIntervalSince1970: 1_789_498_800),
            exposureTime: 1.0 / 250, fNumber: 8, iso: 100)
        let recipe = MergeRecipe(kind: .hdr, clipLevel: 1, lensApplied: false, reference: 0, sources: [])
        return try LinearRawDNGWriter(freeSpaceMargin: 0).write(
            .buffer(pixels, width: width, height: height), maximum: 1, metadata: metadata, recipe: recipe,
            preview: FakeRenders.solid((0.5, 0.5, 0.5), width: 48, height: 32), to: url)
    }
}

@MainActor
final class DustToolTests: XCTestCase {
    nonisolated(unsafe) var folder: URL?
    nonisolated(unsafe) var dng: URL?

    override func setUp() async throws {
        _ = try await GPUContext.shared()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-dust-tool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dng = folder.appendingPathComponent("dust.dng")
        try DustDNG.write(to: dng)
        self.folder = folder
        self.dng = dng
        EditorModel.dustMapStore = DustMapStore(url: folder.appendingPathComponent("dust-maps.json"))
    }

    override func tearDown() async throws {
        EditorModel.dustMapStore = DustMapStore()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func openModel(catalogImageID: Int64? = nil) throws -> EditorModel {
        let model = EditorModel()
        model.open(url: try XCTUnwrap(dng), catalogImageID: catalogImageID)
        XCTAssertTrue(model.hasImage)
        // Opening picks the band the aperture predicts, which for an 800 px
        // "full-frame" sensor is Small; the discs are drawn for Medium.
        model.dustSize = .medium
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    /// Waits for the detached analysis or detection to report back.
    private func waitForDust(_ model: EditorModel) async {
        for _ in 0..<600 where model.findingDust {
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(model.findingDust, "the detection finished")
    }

    private func screenPoint(_ n: SIMD2<Float>, in model: EditorModel) -> CGPoint {
        let sensor = CGPoint(x: CGFloat(n.x) * model.sensorSize.width, y: CGFloat(n.y) * model.sensorSize.height)
        return model.viewport.screenPoint(forSensorPoint: model.frame.canvasPoint(fromSensorPoint: sensor),
                                          drawableSize: model.drawableSize)
    }

    // MARK: - Find Spots

    /// Find Spots after a slider move: the slider's step is saved first,
    /// then the spots as a step of their own, "Sensor Dust", so Undo takes
    /// the spots back and leaves the slider alone. It finds the discs,
    /// arms the tool and keeps the analysis.
    func testFindSpotsAfterASliderMoveGivesTwoHistorySteps() async throws {
        let model = try openModel(catalogImageID: 7)
        XCTAssertEqual(model.history.steps.count, 1)
        model.parameters.exposureEV = 0.5
        XCTAssertNotNil(model.pendingSave, "the slider move is waiting to be saved")

        model.findDustSpots()
        XCTAssertTrue(model.findingDust)
        XCTAssertEqual(model.status, "Looking for dust spots…")
        await waitForDust(model)

        XCTAssertEqual(model.parameters.dust.count, DustDNG.spots.count, "every disc is found once")
        var covered = Set<Int>()
        for patch in model.parameters.dust {
            let spot = try XCTUnwrap(DustDNG.spot(under: patch), "a patch sits on a disc")
            covered.insert(DustDNG.spots.firstIndex(of: spot)!)
            XCTAssertEqual(patch.feather, 0.5)
            XCTAssertEqual(patch.mode, .heal)
            XCTAssertTrue((0...1).contains(patch.source.x) && (0...1).contains(patch.source.y))
        }
        XCTAssertEqual(covered.count, DustDNG.spots.count)
        XCTAssertEqual(model.status, "Found \(DustDNG.spots.count) dust spots")
        XCTAssertTrue(model.dustToolActive, "the rings show")
        XCTAssertNotNil(model.dustAnalysis, "kept for the sensitivity and size controls")
        XCTAssertNil(model.pendingSave, "saved at once")
        XCTAssertEqual(model.history.steps.map(\.label).count, 3)
        XCTAssertNotEqual(model.history.steps[1].label, "Sensor Dust", "the slider's own step")
        XCTAssertEqual(model.history.steps[2].label, "Sensor Dust")

        // Undo takes the spots back and leaves the exposure.
        model.undo()
        XCTAssertTrue(model.parameters.dust.isEmpty)
        XCTAssertEqual(model.parameters.exposureEV, 0.5)
    }

    /// Sensitivity moved while the tool is armed: the list is found again
    /// from the kept analysis, no render; disarming drops the analysis and
    /// the controls do nothing until the next Find Spots.
    func testSensitivityRedetectsFromTheKeptAnalysisWhileArmed() async throws {
        let model = try openModel()
        model.findDustSpots()
        await waitForDust(model)
        XCTAssertEqual(model.parameters.dust.count, DustDNG.spots.count)

        model.dustSensitivity = 100
        model.redetectDustIfArmed()
        XCTAssertTrue(model.findingDust)
        await waitForDust(model)
        XCTAssertEqual(model.parameters.dust.count, DustDNG.spots.count, "the discs are found at any sensitivity")
        XCTAssertNotNil(model.dustAnalysis)
        model.flushPendingSave()

        model.dustToolActive = false
        model.dustToolDidDisarm()
        XCTAssertNil(model.dustAnalysis)
        model.dustSensitivity = 20
        model.redetectDustIfArmed()
        XCTAssertFalse(model.findingDust, "nothing to re-detect from")
    }

    // MARK: - The tool

    /// A click on a ring removes that spot; a click on the image adds one
    /// of the band's middle radius with its source beside it; the cap
    /// refuses the 201st and says so.
    func testRingClickRemovesAndImageClickAddsUpToTheCap() throws {
        let model = try openModel()
        model.dustToolActive = true
        let short = Float(min(model.sensorSize.width, model.sensorSize.height))
        model.parameters.dust = [HealPatch(target: [0.5, 0.5], source: [0.6, 0.5], radius: 12 / short,
                                           feather: 0.5, mode: .heal)]
        model.selectedDustIndex = 0
        XCTAssertNotNil(model.hitDustRing([0.5, 0.5]))
        XCTAssertNil(model.hitDustRing([0.5, 0.6]))

        model.imageToolBegan(at: screenPoint([0.5, 0.5], in: model), exclude: false)
        model.imageToolEnded()
        XCTAssertTrue(model.parameters.dust.isEmpty, "the ring's spot is gone")
        XCTAssertNil(model.selectedDustIndex)

        model.dustSize = .medium
        model.imageToolBegan(at: screenPoint([0.25, 0.5], in: model), exclude: false)
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.dust.count, 1)
        let added = try XCTUnwrap(model.parameters.dust.first)
        XCTAssertEqual(added.target.x, 0.25, accuracy: 0.002)
        XCTAssertEqual(added.target.y, 0.5, accuracy: 0.002)
        XCTAssertEqual(added.radius * short, 1.5 * DustSpotSize.medium.centreRadius + 2, accuracy: 0.01)
        XCTAssertEqual(added.feather, 0.5)
        XCTAssertEqual(added.mode, .heal)
        XCTAssertNotEqual(added.source, added.target)
        XCTAssertTrue((0...1).contains(added.source.x) && (0...1).contains(added.source.y))
        XCTAssertEqual(model.selectedDustIndex, 0)

        // The cap: 200 spots per image, as the sidecar decodes.
        model.parameters.dust = (0..<HealPatch.maximumDustCount).map { i in
            HealPatch(target: [Float(i % 20) / 20 + 0.01, Float(i / 20) / 10 + 0.01], source: [0.5, 0.5],
                      radius: 0.005, feather: 0.5, mode: .heal)
        }
        model.addDustSpot(at: [0.99, 0.99])
        XCTAssertEqual(model.parameters.dust.count, HealPatch.maximumDustCount)
        XCTAssertEqual(model.status, "At most 200 dust spots per image")
    }

    func testDeleteClearAndTheSpokenWords() throws {
        let model = try openModel()
        model.dustToolActive = true
        model.parameters.dust = (0..<3).map {
            HealPatch(target: [0.2 + 0.2 * Float($0), 0.5], source: [0.5, 0.8], radius: 0.01, feather: 0.5, mode: .heal)
        }
        model.selectedDustIndex = 1
        XCTAssertTrue(model.hasSelectedDust)
        model.deleteSelectedDust()
        XCTAssertEqual(model.parameters.dust.count, 2)
        XCTAssertEqual(model.selectedDustIndex, 1, "the next spot is selected")
        model.selectedDustIndex = 1
        model.deleteSelectedDust()
        XCTAssertEqual(model.selectedDustIndex, 0, "the last one steps back")
        model.clearDust()
        XCTAssertTrue(model.parameters.dust.isEmpty)
        XCTAssertNil(model.selectedDustIndex)
        model.deleteSelectedDust()

        var state = CommandState()
        state.mode = .develop
        state.hasImage = true
        state.dustToolActive = true
        XCTAssertFalse(state.isEnabled(.deleteHeal), "nothing selected")
        state.hasSelectedDust = true
        XCTAssertTrue(state.isEnabled(.deleteHeal))
        XCTAssertTrue(state.isEnabled(.dust))

        XCTAssertEqual(SpokenText.dustSpots(count: 0, selected: nil), "No dust spots")
        XCTAssertEqual(SpokenText.dustSpots(count: 1, selected: nil), "1 dust spot")
        XCTAssertEqual(SpokenText.dustSpots(count: 37, selected: 2), "37 dust spots, spot 3 selected")
        XCTAssertEqual(SpokenText.dustFound(added: 0, detected: 0), "No dust spots found")
        XCTAssertEqual(SpokenText.dustFound(added: 0, detected: 3), "Dust spots found already have patches")
        XCTAssertEqual(SpokenText.dustFound(added: 1, detected: 1), "Found 1 dust spot")
        XCTAssertEqual(SpokenText.dustFound(added: 37, detected: 40), "Found 37 dust spots")
    }

    /// Disarming the tool through the other tools' exclusivity, the image
    /// change hooks, the band from the expected radius, and the
    /// visualisation the display output carries.
    func testToolExclusivityImageChangeAndVisualisation() throws {
        let model = try openModel()
        model.dustToolActive = true
        XCTAssertTrue(model.imageToolActive)
        model.healToolActive = true
        XCTAssertFalse(model.dustToolActive)
        model.dustToolActive = true
        XCTAssertFalse(model.healToolActive)
        model.disarmTools()
        XCTAssertFalse(model.dustToolActive)

        // Its aperture is f/8 and a D750 is full frame: the shadow's
        // radius from an 800 px wide "sensor" is tiny, clamped to 2 px.
        XCTAssertEqual(try XCTUnwrap(model.expectedDustRadius), 2.08, accuracy: 0.05)
        model.dustImageDidOpen()
        XCTAssertEqual(model.dustSize, .small)
        XCTAssertEqual(DustSpotSize.band(holding: 5), .small)
        XCTAssertEqual(DustSpotSize.band(holding: 7), .medium, "Medium when two bands hold it")
        XCTAssertEqual(DustSpotSize.band(holding: 14), .medium)
        XCTAssertEqual(DustSpotSize.band(holding: 30), .large)
        XCTAssertEqual(DustSpotSize.band(holding: 60), .large)
        XCTAssertEqual(DustSpotSize.band(holding: 1), .small)
        XCTAssertEqual(DustSpotSize.medium.centreRadius, 11)

        model.dustSize = .medium
        XCTAssertNil(model.dustVisualisation)
        model.visualiseSpots = true
        model.visualiseThreshold = 0.3
        let visualisation = try XCTUnwrap(model.dustVisualisation)
        XCTAssertEqual(visualisation.threshold, 0.3)
        XCTAssertEqual(visualisation.radiusSensorPx, 11, "the band's middle: the expected radius is outside it")
        model.showingBefore = true
        XCTAssertNil(model.dustVisualisation, "Before shows the photo as it came")
        model.showingBefore = false

        model.dustToolActive = true
        model.selectedDustIndex = 0
        model.dustImageWillChange()
        XCTAssertFalse(model.dustToolActive)
        XCTAssertFalse(model.visualiseSpots)
        XCTAssertNil(model.selectedDustIndex)
        XCTAssertNil(model.dustAnalysis)
    }

    // MARK: - Dust maps

    /// Save as dust map… writes the list as a map keyed by the camera
    /// string, with the photo's sensor size, name and aperture.
    func testSaveAsDustMapWritesAMapForTheCamera() async throws {
        let model = try openModel()
        model.saveDustMap()
        XCTAssertEqual(model.status, "No dust spots to save")
        model.findDustSpots()
        await waitForDust(model)
        XCTAssertEqual(model.parameters.dust.count, DustDNG.spots.count)

        model.saveDustMap()
        await waitForDust(model)
        let maps = EditorModel.dustMapStore.load()
        XCTAssertEqual(maps.count, 1)
        let map = try XCTUnwrap(maps.first)
        XCTAssertEqual(map.camera, "Nikon D750")
        XCTAssertEqual(map.sensorSize, SIMD2(DustDNG.width, DustDNG.height))
        XCTAssertEqual(map.referenceName, "dust.dng")
        XCTAssertEqual(map.aperture, 8)
        XCTAssertEqual(map.options, model.dustOptions)
        XCTAssertEqual(map.spots.count, DustDNG.spots.count)
        for spot in map.spots {
            XCTAssertGreaterThan(spot.contrast, 0.2, "a 30 % dip is about half a stop")
        }
        XCTAssertEqual(model.status, "Saved dust map “\(map.title)”")
        XCTAssertEqual(EditorModel.dustMapStore.maps(forCamera: "Nikon D750").count, 1)
    }

    /// From dust map… verifies the map's spots in this photo and appends
    /// the ones that are there, leaving the user's own patches alone; a
    /// map for another camera is refused.
    func testFromMapAppendsWithoutTouchingUserHeals() async throws {
        let model = try openModel(catalogImageID: 9)
        let heal = HealPatch(target: [0.9, 0.9], source: [0.8, 0.9], radius: 0.03)
        model.parameters.heals = [heal]
        model.flushPendingSave()
        let short = Float(min(DustDNG.width, DustDNG.height))
        // The discs, slightly misplaced as a map from another photo is,
        // and a phantom where the sky is clean.
        var spots = DustDNG.spots.map {
            DustMapSpot(centre: ($0.centre + [1.5, -1]) / DustDNG.sensorSize, radius: $0.radius / short, contrast: 0.5)
        }
        spots.append(DustMapSpot(centre: [0.5, 0.75], radius: 10 / short, contrast: 0.5))
        let map = DustMap(camera: "Nikon D750", sensorSize: SIMD2(DustDNG.width, DustDNG.height),
                          referenceName: "sky.dng", spots: spots)

        model.applyDustMap(map, options: DustDetector.Options())
        await waitForDust(model)
        XCTAssertEqual(model.parameters.dust.count, DustDNG.spots.count, "the phantom is not there")
        for patch in model.parameters.dust {
            XCTAssertNotNil(DustDNG.spot(under: patch))
        }
        XCTAssertEqual(model.parameters.heals, [heal], "the user's patch is untouched")
        XCTAssertEqual(model.status, "Found \(DustDNG.spots.count) dust spots")
        XCTAssertTrue(model.dustToolActive)
        XCTAssertEqual(model.history.steps.last?.label, "Sensor Dust")

        // Again: every spot is already patched.
        let before = model.parameters.dust
        model.applyDustMap(map, options: DustDetector.Options())
        await waitForDust(model)
        XCTAssertEqual(model.parameters.dust, before)
        XCTAssertEqual(model.status, "Dust spots found already have patches")

        let other = DustMap(camera: "Canon EOS R5", sensorSize: SIMD2(DustDNG.width, DustDNG.height),
                            referenceName: "sky.cr3", spots: spots)
        model.applyDustMap(other, options: DustDetector.Options())
        XCTAssertFalse(model.findingDust)
        XCTAssertEqual(model.status, "The dust map is for a Canon EOS R5, not this photo’s camera")
        XCTAssertEqual(model.parameters.dust, before)
    }
}
