import XCTest
import AppKit
import simd
import Catalog
import PixelEngine
import MLKit
@testable import latent_app

/// Touch-up in the editor (docs/Retouch.md §7): Find Faces as one history
/// step with thumbnails and masks, when the masks are built again and
/// when they are not, the blemish rings, and what memory pressure does.
/// Vision is stood in for by drawn faces through `EditorModel.touchUpPasses`,
/// so the D750 raw is only a photo to open.
@MainActor
final class TouchUpToolTests: XCTestCase {
    /// The stand-in passes, counting their calls.
    final class FakePasses: @unchecked Sendable {
        private let lock = NSLock()
        private var _finds = 0, _builds = 0, _blemishRuns = 0
        var finds: Int { lock.withLock { _finds } }
        var builds: Int { lock.withLock { _builds } }
        var blemishRuns: Int { lock.withLock { _blemishRuns } }
        /// What Find Faces reports, left to right.
        let boxes: [SIMD4<Float>]
        /// What each Find Blemishes run returns, in order; the last repeats.
        let blemishLists: [[HealPatch]]
        private var _missing: [UUID] = []
        /// Faces regeneration cannot find again.
        var missing: [UUID] {
            get { lock.withLock { _missing } }
            set { lock.withLock { _missing = newValue } }
        }

        init(boxes: [SIMD4<Float>], blemishLists: [[HealPatch]] = [[]]) {
            self.boxes = boxes
            self.blemishLists = blemishLists
        }

        func masks(for faces: [TouchUpFace], sensor: CGSize) -> TouchUpMaskSet {
            TouchUpMaskSet.fixture(sensorWidth: Int(sensor.width), sensorHeight: Int(sensor.height),
                                   faces: faces.map { face in
                let b = face.boundingBox
                return (id: face.id, skin: CGRect(x: CGFloat(b.x), y: CGFloat(b.y), width: CGFloat(b.z), height: CGFloat(b.w)),
                        teeth: nil, eyes: [])
            })
        }

        static func thumbnail() -> CGImage {
            let context = CGContext(data: nil, width: 80, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(red: 0.8, green: 0.6, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            return context.makeImage()!
        }

        var passes: EditorModel.TouchUpPasses {
            EditorModel.TouchUpPasses(
                find: { [self] _, image in
                    lock.withLock { _finds += 1 }
                    let faces = boxes.map { TouchUpFace(boundingBox: $0) }
                    let summary = image.session.file.summary
                    let sensor = CGSize(width: summary.rawWidth, height: summary.rawHeight)
                    return TouchUpRegions.Found(
                        faces: faces, tooSmall: 1, masks: masks(for: faces, sensor: sensor),
                        thumbnails: Dictionary(uniqueKeysWithValues: faces.map { ($0.id, SendableImage(cgImage: Self.thumbnail())) }))
                },
                build: { [self] touchUp, _, image in
                    lock.withLock { _builds += 1 }
                    let summary = image.session.file.summary
                    let sensor = CGSize(width: summary.rawWidth, height: summary.rawHeight)
                    return (masks(for: touchUp.faces, sensor: sensor), missing)
                },
                blemishes: { [self] _, _, _, _, _ in
                    let run = lock.withLock { _blemishRuns += 1; return _blemishRuns }
                    return blemishLists[min(run - 1, blemishLists.count - 1)]
                })
        }
    }

    static let boxes: [SIMD4<Float>] = [SIMD4(0.2, 0.2, 0.2, 0.3), SIMD4(0.55, 0.25, 0.2, 0.3)]

    /// Holds a fake pass until the test lets it go; each `open` lets one
    /// waiter through.
    private final class Gate: @unchecked Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func wait() { semaphore.wait() }
        func open() { semaphore.signal() }
    }

    /// The fake's passes with one of them held at `gate` until opened.
    private func gated(_ fake: FakePasses, build: Gate? = nil, blemishes: Gate? = nil) -> EditorModel.TouchUpPasses {
        var passes = fake.passes
        if let build {
            let inner = passes.build
            passes.build = { touchUp, render, image in build.wait(); return inner(touchUp, render, image) }
        }
        if let blemishes {
            let inner = passes.blemishes
            passes.blemishes = { render, masks, touchUp, existing, image in
                blemishes.wait()
                return inner(render, masks, touchUp, existing, image)
            }
        }
        return passes
    }

    override func tearDown() async throws {
        EditorModel.touchUpPasses = .live
    }

    private func openModel(editStackJSON: String? = nil) async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: 1, editStackJSON: editStackJSON)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    /// The edit as the fake finds it, stored: faces and a slider.
    private func storedFaces(skinSmoothing: Float) throws -> String {
        var p = EditParameters()
        p.touchUp.faces = Self.boxes.map { TouchUpFace(boundingBox: $0) }
        p.touchUp.skinSmoothing = skinSmoothing
        p.touchUp.modelVersion = FaceLandmarker.modelVersion
        return try EditStack(parameters: p).encodeJSON()
    }

    /// The screen point of a raw-normalised sensor point.
    private func screen(_ n: SIMD2<Float>, in model: EditorModel) -> CGPoint {
        let sensor = CGPoint(x: CGFloat(n.x) * model.sensorSize.width, y: CGFloat(n.y) * model.sensorSize.height)
        return model.viewport.screenPoint(forSensorPoint: model.frame.canvasPoint(fromSensorPoint: sensor),
                                          drawableSize: model.drawableSize)
    }

    private func findFaces(_ model: EditorModel) async {
        model.findFaces()
        XCTAssertTrue(model.findingFaces)
        XCTAssertEqual(model.status, "Looking for faces…")
        await waitUntil("Find Faces", seconds: 20) { !model.findingFaces }
    }

    // MARK: - Find Faces

    /// Find Faces after a slider move: the slider is one history step and
    /// the faces another, with a thumbnail per face, the masks on the
    /// session, the version stamp and the spoken result.
    func testFindFacesIsOneHistoryStepWithThumbnailsAndMasks() async throws {
        let fake = FakePasses(boxes: Self.boxes)
        EditorModel.touchUpPasses = fake.passes
        let model = try await openModel()
        let session = try XCTUnwrap(model.session)
        let steps = model.history.steps.count
        model.parameters.exposureEV = 0.5   // pending when Find Faces starts

        await findFaces(model)
        XCTAssertEqual(fake.finds, 1)
        XCTAssertEqual(model.parameters.touchUp.faces.count, 2)
        XCTAssertEqual(model.parameters.touchUp.faces.map(\.boundingBox), Self.boxes)
        XCTAssertEqual(model.parameters.touchUp.modelVersion, FaceLandmarker.modelVersion)
        XCTAssertTrue(model.parameters.touchUp.faces.allSatisfy(\.enabled))
        XCTAssertEqual(model.faceThumbnails.count, 2)
        XCTAssertTrue(session.hasTouchUpMasks)
        XCTAssertEqual(session.touchUpMasks?.faces.count, 2)
        XCTAssertEqual(model.status, "Found 2 faces, 1 too small to retouch")
        XCTAssertEqual(model.touchUpStatus, model.status)
        XCTAssertEqual(model.history.steps.count, steps + 2, "the slider, then the faces")
        XCTAssertEqual(model.history.steps.last?.label, "Touch-up")
        XCTAssertNotNil(model.touchUpGeometryKey)
        XCTAssertEqual(fake.builds, 0, "Find Faces builds the masks itself")

        // A second Find Faces replaces the list (fresh ids) in one more step.
        let firstIDs = model.parameters.touchUp.faces.map(\.id)
        await findFaces(model)
        XCTAssertEqual(model.parameters.touchUp.faces.count, 2)
        XCTAssertNotEqual(model.parameters.touchUp.faces.map(\.id), firstIDs)
        XCTAssertEqual(model.history.steps.count, steps + 3)
    }

    /// Undo after a second Find Faces brings the first list back, whose
    /// ids the session's masks (built for the second) know nothing of:
    /// the set is dropped and built again for the faces shown, with a
    /// thumbnail per face, rather than smoothing nothing.
    func testUndoToOtherFacesBuildsTheirMasks() async throws {
        let fake = FakePasses(boxes: Self.boxes)
        EditorModel.touchUpPasses = fake.passes
        let model = try await openModel()
        let session = try XCTUnwrap(model.session)
        await findFaces(model)
        let firstIDs = model.parameters.touchUp.faces.map(\.id)
        model.parameters.touchUp.skinSmoothing = 60
        await findFaces(model)
        XCTAssertNotEqual(model.parameters.touchUp.faces.map(\.id), firstIDs)
        XCTAssertEqual(fake.builds, 0)

        model.undo()
        XCTAssertEqual(model.parameters.touchUp.faces.map(\.id), firstIDs)
        XCTAssertEqual(model.parameters.touchUp.skinSmoothing, 60)
        XCTAssertNotNil(model.touchUpMaskTask, "the masks are being built for the faces shown")
        await waitUntil("the masks", seconds: 20) { model.touchUpMaskTask == nil }
        XCTAssertEqual(fake.builds, 1)
        XCTAssertEqual(session.touchUpMasks?.faces.map(\.id), firstIDs)
        XCTAssertEqual(Set(model.faceThumbnails.keys), Set(firstIDs))

        // Redo the second list: its masks are built the same way.
        model.redo()
        await waitUntil("the masks again", seconds: 20) { model.touchUpMaskTask == nil }
        XCTAssertEqual(fake.builds, 2)
        XCTAssertEqual(session.touchUpMasks?.faces.map(\.id), model.parameters.touchUp.faces.map(\.id))
    }

    /// A lens or keystone change while a build runs finds a build under
    /// way and schedules nothing; the build that lands is for the grid
    /// before the change, so it is not kept and one for the current grid
    /// follows.
    func testGeometryChangeDuringABuildRebuildsForTheNewGrid() async throws {
        let fake = FakePasses(boxes: Self.boxes)
        let gate = Gate()
        EditorModel.touchUpPasses = gated(fake, build: gate)
        let model = try await openModel(editStackJSON: try storedFaces(skinSmoothing: 40))
        let session = try XCTUnwrap(model.session)
        XCTAssertNotNil(model.touchUpMaskTask, "the on-open build")
        let staleKey = EditorModel.touchUpGeometryKey(of: model.parameters)

        model.parameters.perspective.vertical = 0.2
        let key = EditorModel.touchUpGeometryKey(of: model.parameters)
        XCTAssertNotEqual(key, staleKey)
        gate.open()
        gate.open()   // the second build too
        await waitUntil("both builds", seconds: 20) { fake.builds == 2 && model.touchUpMaskTask == nil }
        XCTAssertTrue(session.hasTouchUpMasks)
        XCTAssertEqual(model.touchUpGeometryKey, key, "the masks are the current grid's")
        XCTAssertEqual(model.faceThumbnails.count, 2)
    }

    /// The same during Find Faces: its masks are recorded for the grid
    /// they were built on, and with the sliders at zero they are dropped
    /// so the first slider to leave zero builds them for the current one.
    func testGeometryChangeDuringFindFacesLeavesNoStaleMasks() async throws {
        let fake = FakePasses(boxes: Self.boxes)
        EditorModel.touchUpPasses = fake.passes
        let model = try await openModel()
        let session = try XCTUnwrap(model.session)
        model.findFaces()
        XCTAssertTrue(model.findingFaces)
        model.parameters.manualDistortion = 0.2   // while Vision looks
        await waitUntil("Find Faces", seconds: 20) { !model.findingFaces }
        XCTAssertEqual(model.parameters.touchUp.faces.count, 2)
        XCTAssertFalse(session.hasTouchUpMasks, "built for the old grid, and no slider wants them")
        XCTAssertEqual(model.faceThumbnails.count, 2)

        model.parameters.touchUp.skinSmoothing = 30
        XCTAssertNotNil(model.touchUpMaskTask)
        await waitUntil("the masks", seconds: 20) { model.touchUpMaskTask == nil }
        XCTAssertTrue(session.hasTouchUpMasks)
        XCTAssertEqual(model.touchUpGeometryKey, EditorModel.touchUpGeometryKey(of: model.parameters))
    }

    /// A face switched off is a parameter change like any other: the
    /// session's set stays as it is (the texture is rebuilt on the next
    /// render from the enabled ids) and nothing is found again.
    func testFaceToggleRebuildsNothing() async throws {
        let fake = FakePasses(boxes: Self.boxes)
        EditorModel.touchUpPasses = fake.passes
        let model = try await openModel()
        let session = try XCTUnwrap(model.session)
        await findFaces(model)
        let set = try XCTUnwrap(session.touchUpMasks)
        let steps = model.history.steps.count

        var old = model.parameters
        model.parameters.touchUp.skinSmoothing = 50
        model.touchUpParametersDidChange(from: old)
        XCTAssertTrue(model.parameters.touchUp.wantsMasks)
        XCTAssertNil(model.touchUpMaskTask, "masks are there already")

        old = model.parameters
        model.parameters.touchUp.faces[0].enabled = false
        model.touchUpParametersDidChange(from: old)
        XCTAssertNil(model.touchUpMaskTask)
        XCTAssertEqual(fake.builds, 0)
        XCTAssertEqual(fake.finds, 1)
        XCTAssertEqual(session.touchUpMasks, set)
        XCTAssertEqual(model.history.steps.count, steps, "no step until the change settles")
        XCTAssertEqual(model.parameters.touchUp.enabledFaceIDs.count, 1)
    }

    /// A lens or keystone change moves the output grid the masks are
    /// sampled on: they are built again from the stored boxes, 300 ms
    /// after the last change, and only once for a burst of changes.
    func testGeometryChangeRebuildsTheMasksAfterADebounce() async throws {
        let fake = FakePasses(boxes: Self.boxes)
        EditorModel.touchUpPasses = fake.passes
        let model = try await openModel()
        let session = try XCTUnwrap(model.session)
        await findFaces(model)
        var old = model.parameters
        model.parameters.touchUp.skinSmoothing = 50
        model.touchUpParametersDidChange(from: old)
        let keyBefore = model.touchUpGeometryKey

        for distortion: Float in [0.1, 0.2, 0.3] {
            old = model.parameters
            model.parameters.manualDistortion = distortion
            model.touchUpParametersDidChange(from: old)
            XCTAssertNotNil(model.touchUpMaskTask, "a build is pending")
        }
        XCTAssertEqual(fake.builds, 0, "not before the debounce")
        await waitUntil("the masks to be built again", seconds: 10) { fake.builds == 1 && model.touchUpMaskTask == nil }
        XCTAssertEqual(fake.builds, 1)
        XCTAssertTrue(session.hasTouchUpMasks)
        XCTAssertNotEqual(model.touchUpGeometryKey, keyBefore)
        XCTAssertEqual(model.touchUpGeometryKey, EditorModel.touchUpGeometryKey(of: model.parameters))

        // The same geometry again: nothing to do.
        old = model.parameters
        model.parameters.exposureEV = 1
        model.touchUpParametersDidChange(from: old)
        XCTAssertNil(model.touchUpMaskTask)

        // Vignetting is not geometry.
        old = model.parameters
        model.parameters.manualVignetting = 0.5
        model.touchUpParametersDidChange(from: old)
        XCTAssertNil(model.touchUpMaskTask)
    }

    /// A photo opened with faces and a slider has no masks on its session
    /// until they are built again (the lead calls this on open); a face
    /// Vision cannot refit is named. With the sliders at zero nothing is
    /// built until a slider leaves zero.
    func testRegenerationOnOpenAndWhenASliderLeavesZero() async throws {
        let fake = FakePasses(boxes: Self.boxes)
        EditorModel.touchUpPasses = fake.passes
        let withSlider = try await openModel(editStackJSON: try storedFaces(skinSmoothing: 40))
        let session = try XCTUnwrap(withSlider.session)
        XCTAssertFalse(session.hasTouchUpMasks)
        XCTAssertTrue(withSlider.faceThumbnails.isEmpty)
        fake.missing = [withSlider.parameters.touchUp.faces[1].id]
        withSlider.regenerateTouchUpMasksIfNeeded()
        XCTAssertNotNil(withSlider.touchUpMaskTask)
        await waitUntil("the masks", seconds: 20) { withSlider.touchUpMaskTask == nil }
        XCTAssertEqual(fake.builds, 1)
        XCTAssertTrue(session.hasTouchUpMasks)
        XCTAssertEqual(withSlider.faceThumbnails.count, 2, "thumbnails from the analysis render")
        XCTAssertEqual(withSlider.status, "Face 2 could not be found again")
        withSlider.regenerateTouchUpMasksIfNeeded()
        XCTAssertNil(withSlider.touchUpMaskTask, "nothing to do with masks in place")

        let atZero = try await openModel(editStackJSON: try storedFaces(skinSmoothing: 0))
        let zeroSession = try XCTUnwrap(atZero.session)
        atZero.regenerateTouchUpMasksIfNeeded()
        XCTAssertNil(atZero.touchUpMaskTask, "the stage doesn't run at zero")
        let old = atZero.parameters
        atZero.parameters.touchUp.teethWhitening = 30
        atZero.touchUpParametersDidChange(from: old)
        XCTAssertNotNil(atZero.touchUpMaskTask)
        await waitUntil("the masks", seconds: 20) { atZero.touchUpMaskTask == nil }
        XCTAssertTrue(zeroSession.hasTouchUpMasks)
        XCTAssertEqual(fake.builds, 2)
    }

    // MARK: - Blemishes

    /// With the tool armed, a click on skin adds a patch 0.3 % of the face
    /// across (switching removal on), a click on its ring removes it, a
    /// click off the faces does nothing, and ⌫ reaches the selected one.
    func testClicksAddAndRemoveBlemishRings() async throws {
        EditorModel.touchUpPasses = FakePasses(boxes: Self.boxes).passes
        let model = try await openModel()
        await findFaces(model)
        model.touchUpToolActive = true
        XCTAssertTrue(model.imageToolActive)

        let onSkin = SIMD2<Float>(0.3, 0.35)   // inside the first box
        model.imageToolBegan(at: screen(onSkin, in: model), exclude: false)
        model.imageToolEnded()
        let blemishes = model.parameters.touchUp.blemishes
        XCTAssertEqual(blemishes.count, 1)
        XCTAssertTrue(model.parameters.touchUp.blemishRemoval)
        XCTAssertEqual(model.selectedBlemishIndex, 0)
        XCTAssertTrue(model.hasSelectedBlemish)
        let patch = try XCTUnwrap(blemishes.first)
        XCTAssertEqual(simd_distance(patch.target, onSkin), 0, accuracy: 0.002)
        let short = Float(min(model.sensorSize.width, model.sensorSize.height))
        XCTAssertEqual(patch.radius * short, 0.003 * 0.2 * Float(model.sensorSize.width), accuracy: 1)
        XCTAssertEqual(patch.feather, 0.5)
        XCTAssertEqual(patch.mode, .heal)
        XCTAssertNotEqual(patch.source, patch.target)
        let b = Self.boxes[0]
        XCTAssertTrue(patch.source.x >= b.x && patch.source.x <= b.x + b.z && patch.source.y >= b.y && patch.source.y <= b.y + b.w,
                      "the source stays on the face: \(patch.source)")

        var state = CommandState()
        state.mode = .develop
        state.hasImage = true
        state.touchUpToolActive = true
        XCTAssertFalse(state.isEnabled(.deleteHeal))
        state.hasSelectedBlemish = model.hasSelectedBlemish
        XCTAssertTrue(state.isEnabled(.deleteHeal))

        // The ring: removed, not moved.
        model.imageToolBegan(at: screen(onSkin, in: model), exclude: false)
        model.imageToolEnded()
        XCTAssertTrue(model.parameters.touchUp.blemishes.isEmpty)
        XCTAssertNil(model.selectedBlemishIndex)

        // Off every face: nothing.
        model.imageToolBegan(at: screen(SIMD2(0.05, 0.9), in: model), exclude: false)
        model.imageToolEnded()
        XCTAssertTrue(model.parameters.touchUp.blemishes.isEmpty)

        // ⌫ on the selected one; Clear on the rest.
        model.imageToolBegan(at: screen(onSkin, in: model), exclude: false)
        model.imageToolEnded()
        model.imageToolBegan(at: screen(SIMD2(0.6, 0.4), in: model), exclude: false)
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.touchUp.blemishes.count, 2)
        XCTAssertEqual(model.selectedBlemishIndex, 1)
        model.deleteSelectedBlemish()
        XCTAssertEqual(model.parameters.touchUp.blemishes.count, 1)
        XCTAssertEqual(model.selectedBlemishIndex, 0)
        model.clearBlemishes()
        XCTAssertTrue(model.parameters.touchUp.blemishes.isEmpty)
        XCTAssertNil(model.selectedBlemishIndex)

        // Disarming drops the selection; a face switched off takes no clicks.
        model.imageToolBegan(at: screen(onSkin, in: model), exclude: false)
        model.touchUpToolActive = false
        XCTAssertNil(model.selectedBlemishIndex)
        model.touchUpToolActive = true
        model.parameters.touchUp.faces[0].enabled = false
        model.imageToolBegan(at: screen(SIMD2(0.25, 0.3), in: model), exclude: false)
        XCTAssertEqual(model.parameters.touchUp.blemishes.count, 1)
    }

    /// With a lens correction on, the viewport shows the corrected image
    /// while a patch heals the raw grid before the lens stage: a click
    /// goes through the lens map to the raw pixel under the cursor, and
    /// its ring (drawn back through the map) takes the next click.
    func testClicksGoThroughTheLensMapToTheRawGrid() async throws {
        EditorModel.touchUpPasses = FakePasses(boxes: Self.boxes).passes
        let model = try await openModel()
        await findFaces(model)
        model.parameters.manualDistortion = 0.3
        model.touchUpToolActive = true
        let size = SIMD2(Float(model.sensorSize.width), Float(model.sensorSize.height))
        let raw = SIMD2<Float>(0.3, 0.35)   // inside the first box, off centre
        let out = model.outputNormalized(raw)
        XCTAssertGreaterThan(simd_length((out - raw) * size), 2, "the distortion moves the point by pixels")
        XCTAssertEqual(simd_length((model.rawNormalized(out) - raw) * size), 0, accuracy: 0.05)

        model.imageToolBegan(at: screen(out, in: model), exclude: false)
        model.imageToolEnded()
        let patch = try XCTUnwrap(model.parameters.touchUp.blemishes.first)
        XCTAssertEqual(simd_length((patch.target - raw) * size), 0, accuracy: 0.5, "the raw pixel under the cursor")
        XCTAssertNotEqual(patch.source, patch.target)
        let b = Self.boxes[0]
        XCTAssertTrue(patch.source.x >= b.x && patch.source.x <= b.x + b.z && patch.source.y >= b.y && patch.source.y <= b.y + b.w,
                      "the source stays on the face: \(patch.source)")

        // The ring is drawn where the click was; the same click removes it.
        model.imageToolBegan(at: screen(out, in: model), exclude: false)
        XCTAssertTrue(model.parameters.touchUp.blemishes.isEmpty)
    }

    /// Find Blemishes replaces the list each time, as one history step,
    /// and says what it found.
    func testFindBlemishesReplacesTheList() async throws {
        func patch(_ x: Float, _ y: Float) -> HealPatch {
            HealPatch(target: SIMD2(x, y), source: SIMD2(x + 0.01, y), radius: 0.002, feather: 0.5)
        }
        let fake = FakePasses(boxes: Self.boxes,
                              blemishLists: [[patch(0.25, 0.3), patch(0.3, 0.35), patch(0.6, 0.4)], [patch(0.28, 0.32)]])
        EditorModel.touchUpPasses = fake.passes
        let model = try await openModel()
        model.findBlemishes()
        XCTAssertFalse(model.findingBlemishes, "no face to look on")
        XCTAssertEqual(model.status, "Find Faces first: there is no face to look for blemishes on")
        XCTAssertEqual(fake.blemishRuns, 0)
        await findFaces(model)

        // Faces found but every one switched off: a tick is what's needed,
        // not another Find Faces (which would replace the list).
        model.parameters.touchUp.faces[0].enabled = false
        model.parameters.touchUp.faces[1].enabled = false
        model.findBlemishes()
        XCTAssertFalse(model.findingBlemishes)
        XCTAssertEqual(model.status, "Turn on a face to look for blemishes on it")
        XCTAssertEqual(fake.blemishRuns, 0)
        model.parameters.touchUp.faces[0].enabled = true
        model.parameters.touchUp.faces[1].enabled = true
        model.flushPendingSave()
        let steps = model.history.steps.count

        model.findBlemishes()
        XCTAssertTrue(model.findingBlemishes)
        XCTAssertEqual(model.status, "Looking for blemishes…")
        await waitUntil("Find Blemishes", seconds: 20) { !model.findingBlemishes }
        XCTAssertEqual(model.parameters.touchUp.blemishes.count, 3)
        XCTAssertTrue(model.parameters.touchUp.blemishRemoval)
        XCTAssertEqual(model.status, "Found 3 blemishes")
        XCTAssertEqual(model.history.steps.count, steps + 1)
        XCTAssertEqual(model.history.steps.last?.label, "Touch-up")

        model.findBlemishes()
        await waitUntil("Find Blemishes again", seconds: 20) { !model.findingBlemishes }
        XCTAssertEqual(model.parameters.touchUp.blemishes.count, 1)
        XCTAssertEqual(model.status, "Found 1 blemish")
        XCTAssertEqual(model.history.steps.count, steps + 2)
        XCTAssertEqual(fake.blemishRuns, 2)
    }

    /// While Find Blemishes runs its list is about to replace the edit's:
    /// a click on skin waits rather than adding a ring the result takes
    /// away, and a slider moved meanwhile is a history step of its own
    /// before the blemishes' step, not folded into it.
    func testEditsWhileFindBlemishesRunsAreKept() async throws {
        let found = [HealPatch(target: SIMD2(0.25, 0.3), source: SIMD2(0.26, 0.3), radius: 0.002, feather: 0.5)]
        let fake = FakePasses(boxes: Self.boxes, blemishLists: [found])
        let gate = Gate()
        EditorModel.touchUpPasses = gated(fake, blemishes: gate)
        let model = try await openModel()
        await findFaces(model)
        model.touchUpToolActive = true
        let steps = model.history.steps.count

        model.findBlemishes()
        XCTAssertTrue(model.findingBlemishes)
        model.imageToolBegan(at: screen(SIMD2(0.3, 0.35), in: model), exclude: false)
        model.imageToolEnded()
        XCTAssertTrue(model.parameters.touchUp.blemishes.isEmpty, "the click waits for the search")
        model.parameters.touchUp.skinSmoothing = 40
        XCTAssertNotNil(model.pendingSave)

        gate.open()
        await waitUntil("Find Blemishes", seconds: 20) { !model.findingBlemishes }
        XCTAssertEqual(model.parameters.touchUp.blemishes, found)
        XCTAssertEqual(model.parameters.touchUp.skinSmoothing, 40)
        XCTAssertEqual(model.history.steps.count, steps + 2, "the slider, then the blemishes")
        XCTAssertEqual(model.history.steps.last?.label, "Touch-up")
        model.undo()
        XCTAssertTrue(model.parameters.touchUp.blemishes.isEmpty)
        XCTAssertEqual(model.parameters.touchUp.skinSmoothing, 40, "the slider's step is its own")

        model.imageToolBegan(at: screen(SIMD2(0.3, 0.35), in: model), exclude: false)
        XCTAssertEqual(model.parameters.touchUp.blemishes.count, 1, "clicks work again")
    }

    // MARK: - Memory pressure

    /// Critical pressure takes the session's mask set; the editor notes
    /// it, says so, builds nothing while the shortage lasts, and builds
    /// the masks again when pressure lifts.
    func testMasksComeBackWhenMemoryRecovers() async throws {
        let fake = FakePasses(boxes: Self.boxes)
        EditorModel.touchUpPasses = fake.passes
        let model = try await openModel()
        let session = try XCTUnwrap(model.session)
        await findFaces(model)
        model.parameters.touchUp.skinSmoothing = 60
        XCTAssertTrue(session.hasTouchUpMasks)

        session.releaseMemory(for: .critical)
        XCTAssertFalse(session.hasTouchUpMasks)
        XCTAssertTrue(session.droppedTouchUpMasks)
        model.touchUpMemoryDidDrop()
        XCTAssertTrue(model.touchUpReleasedUnderPressure)
        XCTAssertEqual(model.status, "Memory is low: touch-up will show again when memory recovers")
        model.regenerateTouchUpMasksIfNeeded()
        XCTAssertNil(model.touchUpMaskTask, "nothing is built in the middle of the shortage")
        let old = model.parameters
        model.parameters.touchUp.eyes = 20
        model.touchUpParametersDidChange(from: old)
        XCTAssertNil(model.touchUpMaskTask)

        model.touchUpMemoryDidRecover()
        XCTAssertFalse(model.touchUpReleasedUnderPressure)
        XCTAssertNotNil(model.touchUpMaskTask)
        await waitUntil("the masks to come back", seconds: 20) { model.touchUpMaskTask == nil }
        XCTAssertEqual(fake.builds, 1)
        XCTAssertTrue(session.hasTouchUpMasks)
        XCTAssertFalse(session.droppedTouchUpMasks)
        model.touchUpMemoryDidRecover()
        XCTAssertNil(model.touchUpMaskTask, "recovering twice builds nothing more")
    }

    /// Opening another photo leaves nothing of this one's touch-up behind.
    func testResetForANewImage() async throws {
        EditorModel.touchUpPasses = FakePasses(boxes: Self.boxes).passes
        let model = try await openModel()
        await findFaces(model)
        model.parameters.touchUp.skinSmoothing = 50
        model.showSkinMask = true
        model.touchUpStatus = "Found 2 faces"
        model.selectedBlemishIndex = 0
        XCTAssertTrue(model.touchUpOverlayWanted)
        model.resetTouchUpForNewImage()
        XCTAssertTrue(model.faceThumbnails.isEmpty)
        XCTAssertEqual(model.touchUpStatus, "")
        XCTAssertFalse(model.showSkinMask)
        XCTAssertNil(model.selectedBlemishIndex)
        XCTAssertNil(model.touchUpGeometryKey)
        XCTAssertNil(model.touchUpMaskTask)
        XCTAssertFalse(model.touchUpOverlayWanted)
    }

    /// The real passes on the D750 raw: the analysis render, Vision and
    /// the mask build run to the end and report, and the time they take
    /// in the editor is printed for the plan's record.
    func testFindFacesRunsTheRealPassesInTheEditor() async throws {
        EditorModel.touchUpPasses = .live
        let model = try await openModel()
        let started = Date()
        model.findFaces()
        XCTAssertTrue(model.findingFaces)
        await waitUntil("Find Faces", seconds: 60) { !model.findingFaces }
        let elapsed = Date().timeIntervalSince(started)
        let faces = model.parameters.touchUp.faces.count
        XCTAssertTrue(model.status.hasPrefix(faces == 0 ? "No faces found" : "Found \(faces) face"), model.status)
        XCTAssertEqual(model.faceThumbnails.count, faces)
        XCTAssertEqual(try XCTUnwrap(model.session).touchUpMasks?.faces.count, faces)
        print("Find Faces in the editor on the D750 raw: \(Int(elapsed * 1000)) ms, \(model.status)")
    }

    // MARK: - Wording and the batch job

    func testSpokenResults() {
        XCTAssertEqual(SpokenText.facesFound(found: 0, tooSmall: 0), "No faces found")
        XCTAssertEqual(SpokenText.facesFound(found: 1, tooSmall: 0), "Found 1 face")
        XCTAssertEqual(SpokenText.facesFound(found: 2, tooSmall: 0), "Found 2 faces")
        XCTAssertEqual(SpokenText.facesFound(found: 2, tooSmall: 1), "Found 2 faces, 1 too small to retouch")
        XCTAssertEqual(SpokenText.facesFound(found: 0, tooSmall: 2), "No faces found, 2 too small to retouch")
        XCTAssertEqual(SpokenText.blemishesFound(0), "No blemishes found")
        XCTAssertEqual(SpokenText.blemishesFound(1), "Found 1 blemish")
        XCTAssertEqual(SpokenText.blemishesFound(12), "Found 12 blemishes")
        XCTAssertEqual(SpokenText.blemishes(count: 0, selected: nil), "No blemishes")
        XCTAssertEqual(SpokenText.blemishes(count: 3, selected: 1), "3 blemishes, blemish 2 selected")
        XCTAssertEqual(SpokenText.blemishCount(12), "12 blemishes")
    }

    /// Which stored modules the Library's Find Faces runs over, and what
    /// the job says when done.
    func testFaceFindJobTargetsAndWording() {
        var t = TouchUp()
        XCTAssertFalse(FaceFindJob.needsFaces(nil))
        XCTAssertFalse(FaceFindJob.needsFaces(t), "neutral")
        t.skinSmoothing = 30
        XCTAssertTrue(FaceFindJob.needsFaces(t))
        t.skinSmoothing = 0
        t.blemishRemoval = true
        XCTAssertTrue(FaceFindJob.needsFaces(t))
        t.faces = [TouchUpFace(boundingBox: SIMD4(0.1, 0.1, 0.2, 0.2))]
        XCTAssertFalse(FaceFindJob.needsFaces(t), "it has its faces")

        let job = FaceFindJob()
        XCTAssertEqual(job.title, "Finding faces")
        XCTAssertEqual(job.undoName, "Find Faces")
        XCTAssertEqual(job.outputKind, .findFaces)
        XCTAssertEqual(job.summary(changed: 8, counted: 8, skipped: 0, elapsed: 12), "Found faces in 8 photos")
        XCTAssertEqual(job.summary(changed: 1, counted: 3, skipped: 2, elapsed: 12), "Found faces in 1 photo (3 faces) · 2 skipped")
        XCTAssertEqual(job.announcement(changed: 8), "Found faces in 8 photos")
        XCTAssertEqual(job.announcement(changed: 0), "Face search finished: no faces found")
    }
}
