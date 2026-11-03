import XCTest
import AppKit
import simd
import PixelEngine
import MLKit
@testable import latent_app

/// Regression tests for the editor fixes of the November review: undo
/// and the save debounce, history for uncatalogued files, stored history
/// that could not be read, per-image tool state, mask tools, pasted and
/// geometry-dependent model masks, and the tile's neighbourhood reach.
@MainActor
final class EditorFixesTests: XCTestCase {
    private static let vision = "vision.foregroundInstance@1"

    private func openModel(catalogImageID: Int64? = 1, editStackJSON: String? = nil) async throws -> EditorModel {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.onEditSettled = { _, _ in }
        model.open(url: url, catalogImageID: catalogImageID, editStackJSON: editStackJSON)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        return model
    }

    private func reopen(_ model: EditorModel, editStackJSON: String? = nil) throws {
        model.open(url: try TestAssets.d750URL(), catalogImageID: 2, editStackJSON: editStackJSON)
        XCTAssertTrue(model.hasImage)
    }

    // MARK: - Undo and the save debounce (#101)

    /// A change still in the 1 s debounce is recorded before Undo moves
    /// the cursor, so Undo takes back that change alone and Redo returns it.
    func testUndoRightAfterAChangeUndoesOnlyThatChange() async throws {
        let model = try await openModel()
        model.parameters.exposureEV = 1
        model.flushPendingSave()
        XCTAssertEqual(model.history.steps.count, 2)
        model.parameters.contrast = 0.4
        XCTAssertNotNil(model.pendingSave, "the contrast change is still waiting")

        model.undo()
        XCTAssertEqual(model.parameters.exposureEV, 1, "the earlier step stays")
        XCTAssertEqual(model.parameters.contrast, model.defaultParameters.contrast)
        XCTAssertEqual(model.history.steps.count, 3)
        model.redo()
        XCTAssertEqual(model.parameters.contrast, 0.4, "the latest change can be redone")
        XCTAssertEqual(model.parameters.exposureEV, 1)
    }

    /// The same for a history jump and a snapshot restore.
    func testJumpAndSnapshotRecordThePendingChangeFirst() async throws {
        let model = try await openModel()
        model.saveSnapshot(named: "Start")
        model.parameters.exposureEV = 0.5
        model.jumpToHistory(index: 0)
        XCTAssertEqual(model.history.steps.count, 2, "the pending change is a step")
        model.jumpToHistory(index: 1)
        XCTAssertEqual(model.parameters.exposureEV, 0.5)

        model.parameters.contrast = 0.2
        model.restoreSnapshot(try XCTUnwrap(model.snapshots.first))
        XCTAssertTrue(model.history.steps.contains { $0.stack.parameters(defaults: model.defaultParameters).contrast == 0.2 },
                      "the change made before the restore is in the history")
    }

    // MARK: - History without a catalog id (#107)

    func testUndoWorksForAFileOpenedWithoutACatalog() async throws {
        let model = try await openModel(catalogImageID: nil)
        var settled = 0
        model.onEditSettled = { _, _ in settled += 1 }
        model.parameters.exposureEV = 0.7
        XCTAssertNotNil(model.pendingSave, "the settle is scheduled without an id")
        model.flushPendingSave()
        XCTAssertEqual(model.history.steps.count, 2)
        XCTAssertTrue(model.canUndo)
        XCTAssertEqual(settled, 0, "nothing is written for an uncatalogued file")
        model.undo()
        XCTAssertEqual(model.parameters.exposureEV, model.defaultParameters.exposureEV)
        XCTAssertTrue(model.canRedo)
    }

    /// The debounce itself records the step, not only an explicit flush.
    func testTheDebounceRecordsAStepWithoutACatalog() async throws {
        let model = try await openModel(catalogImageID: nil)
        model.parameters.exposureEV = 0.3
        await waitUntil("the debounce", seconds: 5) { model.history.steps.count == 2 }
    }

    // MARK: - Stored history that was not read (#177)

    func testHistoryAndSnapshotsAreNotOverwrittenBeforeTheyAreRead() async throws {
        let model = try await openModel()
        var historyWrites: [[(stackJSON: String, createdAt: Int64)]] = []
        var snapshotWrites: [[(name: String, stackJSON: String)]] = []
        model.onHistoryChanged = { _, steps in historyWrites.append(steps) }
        model.onSnapshotsChanged = { _, snaps in snapshotWrites.append(snaps) }

        // The read failed (ContentView never calls loadHistory).
        model.parameters.exposureEV = 0.4
        model.flushPendingSave()
        model.saveSnapshot(named: "X")
        XCTAssertTrue(historyWrites.isEmpty, "the stored history is not replaced")
        XCTAssertTrue(snapshotWrites.isEmpty, "the stored snapshots are not replaced")
        XCTAssertTrue(model.status.contains("this session only"), model.status)
        XCTAssertEqual(model.history.steps.count, 2, "undo still works in memory")
    }

    func testUnreadableRowsAreWrittenBack() async throws {
        let model = try await openModel()
        var historyWrites: [[(stackJSON: String, createdAt: Int64)]] = []
        var snapshotWrites: [[(name: String, stackJSON: String)]] = []
        model.onHistoryChanged = { _, steps in historyWrites.append(steps) }
        model.onSnapshotsChanged = { _, snaps in snapshotWrites.append(snaps) }
        let good = try EditStack(parameters: model.defaultParameters).encodeJSON()
        model.loadHistory(steps: [(good, 1000), ("{not json", 2000)],
                          snapshots: [("Good", good), ("Future", "{not json")])
        XCTAssertEqual(model.snapshots.map(\.name), ["Good"])

        model.saveSnapshot(named: "X")
        let snaps = try XCTUnwrap(snapshotWrites.last)
        XCTAssertEqual(Set(snaps.map(\.name)), ["Good", "Future", "X"])
        model.parameters.exposureEV = 0.2
        model.flushPendingSave()
        let steps = try XCTUnwrap(historyWrites.last)
        XCTAssertTrue(steps.contains { $0.stackJSON == "{not json" }, "the unread step is kept")
        XCTAssertEqual(steps.map(\.createdAt), steps.map(\.createdAt).sorted())

        model.deleteSnapshot(EditSnapshot(name: "Future", stack: EditStack()))
        XCTAssertEqual(Set(try XCTUnwrap(snapshotWrites.last).map(\.name)), ["Good", "X"],
                       "deleting by name removes an unread one too")
    }

    // MARK: - Per-image tool state (#103, #104)

    func testStraightenStartsFromTheNewPhotosCrop() async throws {
        let model = try await openModel()
        model.cropToolActive = true
        model.setStraighten(5)
        XCTAssertNotNil(model.straightenBase)

        var p = model.defaultParameters
        p.crop = CropParameters(centre: [0.4, 0.45], size: [0.5, 0.5])
        try reopen(model, editStackJSON: EditStack(parameters: p).encodeJSON())
        XCTAssertNil(model.straightenBase, "the last photo's crop is not the base")
        XCTAssertTrue(model.cropToolActive, "the tool stays on, as before")
        model.setStraighten(3)
        XCTAssertEqual(model.parameters.crop.angle, 3)
        XCTAssertEqual(model.parameters.crop.centre.x, 0.4, accuracy: 0.02)
        XCTAssertEqual(model.parameters.crop.centre.y, 0.45, accuracy: 0.02)
        XCTAssertLessThanOrEqual(model.parameters.crop.size.x, 0.5 + 1e-4)
    }

    func testOpeningResetsSelectionsAndDragsOfThePreviousPhoto() async throws {
        var p = EditParameters()
        p.heals = (0..<4).map { HealPatch(target: [0.2 + Float($0) * 0.1, 0.5], source: [0.2, 0.3], radius: 0.02) }
        let json = try EditStack(parameters: p).encodeJSON()
        let model = try await openModel(editStackJSON: json)
        model.healToolActive = true
        model.selectedHealIndex = 3
        model.selectedRedEyeIndex = 0
        model.healDrag = .painting
        model.paintingHealStroke = [[0.1, 0.1], [0.2, 0.2]]
        model.redEyeDrag = .sizing(0)

        try reopen(model, editStackJSON: json)
        XCTAssertNil(model.selectedHealIndex)
        XCTAssertNil(model.selectedRedEyeIndex)
        XCTAssertNil(model.healDrag)
        XCTAssertNil(model.redEyeDrag)
        XCTAssertTrue(model.paintingHealStroke.isEmpty)
        let heals = model.parameters.heals
        model.healToolEnded()
        XCTAssertEqual(model.parameters.heals, heals, "a stroke begun on the last photo is not committed here")

        model.parameters.locals = [LocalAdjustment(name: "B", shape: .brush(strokes: []))]
        model.selectedLocalIndex = 0
        model.maskTool = .brush
        model.isDraggingMask = true
        try reopen(model)
        XCTAssertNil(model.selectedLocalIndex)
        XCTAssertEqual(model.maskTool, .none)
        XCTAssertFalse(model.isDraggingMask)
    }

    // MARK: - Mask tools (#102, #105)

    func testDeletingALocalDisarmsTheToolAimedAtIt() async throws {
        let model = try await openModel()
        let stroke = BrushStroke(points: [[0.5, 0.5]], radius: 0.04, feather: 0.5, flow: 1, erase: false)
        model.parameters.locals = [
            LocalAdjustment(name: "Gradient 1", shape: .linear(start: [0.5, 0], end: [0.5, 0.5])),
            LocalAdjustment(name: "Brush 2", shape: .brush(strokes: [stroke])),
        ]
        model.selectedLocalIndex = 0
        model.maskTool = .linear
        model.removeSelectedLocal()
        XCTAssertEqual(model.selectedLocalIndex, 0)
        XCTAssertEqual(model.maskTool, .none, "the gradient tool is not left armed over Brush 2")

        // Even armed by hand, a tool only reshapes a local of its kind.
        model.maskTool = .linear
        model.maskToolBegan(at: CGPoint(x: 300, y: 300))
        model.maskToolMoved(to: CGPoint(x: 400, y: 400))
        model.maskToolEnded()
        XCTAssertEqual(model.parameters.locals[0].shape, .brush(strokes: [stroke]))
        model.maskTool = .radial
        model.maskToolBegan(at: CGPoint(x: 300, y: 300))
        model.maskToolEnded()
        XCTAssertEqual(model.parameters.locals[0].shape, .brush(strokes: [stroke]))
    }

    func testUndoThatMovesTheSelectionDisarmsTheMaskTool() async throws {
        let model = try await openModel()
        model.parameters.locals = [LocalAdjustment(name: "Brush 1", shape: .brush(strokes: []))]
        model.flushPendingSave()
        model.parameters.locals.insert(LocalAdjustment(name: "Gradient", shape: .linear(start: .zero, end: .one)), at: 0)
        model.selectedLocalIndex = 0
        model.maskTool = .linear
        model.undo()
        XCTAssertEqual(model.maskTool, .none)
    }

    func testArmingAMaskToolDisarmsHealRedEyeAndCrop() async throws {
        let model = try await openModel()
        model.healToolActive = true
        model.addLocal(.linear)
        XCTAssertEqual(model.maskTool, .linear)
        XCTAssertFalse(model.healToolActive)
        let heals = model.parameters.heals.count
        model.imageToolBegan(at: CGPoint(x: 600, y: 400), exclude: false)
        model.imageToolMoved(to: CGPoint(x: 600, y: 600))
        model.imageToolEnded()
        XCTAssertEqual(model.parameters.heals.count, heals, "the drag placed the gradient, not a patch")
        if case .linear(let start, let end) = model.parameters.locals[0].shape {
            XCTAssertNotEqual(start, end)
        } else { XCTFail("still a gradient") }

        model.redEyeToolActive = true
        model.maskTool = .radial
        XCTAssertFalse(model.redEyeToolActive)
        model.cropToolActive = true
        XCTAssertEqual(model.maskTool, .none, "crop disarms the mask tool")
        model.maskTool = .linear
        XCTAssertFalse(model.cropToolActive, "and the mask tool disarms crop")
    }

    // MARK: - Model masks (#109, #108)

    func testPastedModelMasksAreGenerated() async throws {
        let model = try await openModel()
        let session = try XCTUnwrap(model.session)
        let local = LocalAdjustment(name: "Subject", shape: .ai(kind: "subject", modelVersion: Self.vision))
        var pasted = model.defaultParameters
        pasted.locals = [local]
        model.apply(EditStack(parameters: pasted), groups: [.locals])
        XCTAssertTrue(model.generatingMasks.contains(local.id) || session.hasAIMask(forLocal: local.id),
                      "the pasted mask is being made")

        // This image already has pixels under the id, for another model:
        // they go and the pasted shape's are made.
        let other = LocalAdjustment(id: local.id, name: "Subject",
                                    shape: .ai(kind: "subject", modelVersion: "birefnet-lite@1"))
        await waitUntil("the first mask", seconds: 60) { !model.generatingMasks.contains(local.id) }
        session.setAIMask(MaskBitmap(width: 1, height: 1, data: [255]), forLocal: local.id)
        pasted.locals = [other]
        model.apply(EditStack(parameters: pasted), groups: [.locals])
        XCTAssertFalse(session.hasAIMask(forLocal: local.id) && !model.generatingMasks.contains(local.id),
                       "the old pixels are not kept for the new shape")
        XCTAssertTrue(model.generatingMasks.contains(local.id))
    }

    func testModelMaskInputCarriesTheEditsGeometryOnly() {
        var defaults = EditParameters()
        defaults.exposureEV = 0
        var edit = EditParameters()
        edit.perspective = PerspectiveCorrection(vertical: 0.5, horizontal: 0)
        edit.manualDistortion = 0.1
        edit.lensDistortion = !defaults.lensDistortion
        edit.exposureEV = 2
        edit.locals = [LocalAdjustment(name: "G", shape: .whole)]
        let input = ExportWorker.modelMaskInputParameters(defaults: defaults, geometry: edit)
        XCTAssertEqual(input.perspective, edit.perspective)
        XCTAssertEqual(input.manualDistortion, 0.1)
        XCTAssertEqual(input.lensDistortion, edit.lensDistortion)
        XCTAssertEqual(input.exposureEV, 0, "the look stays the camera's")
        XCTAssertTrue(input.locals.isEmpty)
    }

    func testAGeometryChangeMakesModelMasksAgain() async throws {
        let model = try await openModel()
        let session = try XCTUnwrap(model.session)
        let local = LocalAdjustment(name: "Subject", shape: .ai(kind: "subject", modelVersion: Self.vision))
        model.parameters.locals = [local]
        model.regenerateMissingAIMasks()
        XCTAssertEqual(model.modelMaskGeometry[local.id], EditorModel.touchUpGeometryKey(of: model.parameters))
        await waitUntil("the mask", seconds: 60) { !model.generatingMasks.contains(local.id) }
        session.setAIMask(MaskBitmap(width: 1, height: 1, data: [255]), forLocal: local.id)

        model.parameters.manualDistortion = 0.1
        // A colour change is not geometry and leaves the mask alone.
        model.parameters.exposureEV = 0.5
        await waitUntil("the rebuild", seconds: 5) {
            model.modelMaskGeometry[local.id] == EditorModel.touchUpGeometryKey(of: model.parameters)
        }
        XCTAssertTrue(model.generatingMasks.contains(local.id), "the mask is being made again")
        XCTAssertFalse(session.hasAIMask(forLocal: local.id), "the default-grid pixels were dropped")
        await waitUntil("the new mask", seconds: 60) { !model.generatingMasks.contains(local.id) }

        // Unchanged geometry: nothing is rebuilt.
        session.setAIMask(MaskBitmap(width: 1, height: 1, data: [255]), forLocal: local.id)
        model.regenerateModelMasksMadeOnAnotherGrid()
        XCTAssertTrue(session.hasAIMask(forLocal: local.id))
        XCTAssertFalse(model.generatingMasks.contains(local.id))
    }

    // MARK: - Tile reach (#47)

    func testTheTileNeverShowsTheBandPresenceClamped() async throws {
        let model = try await openModel()
        XCTAssertEqual(EditorModel.neighbourhoodReach(of: model.parameters, sensorSize: model.sensorSize), 0)
        model.parameters.clarity = 0.6
        let reach = EditorModel.neighbourhoodReach(of: model.parameters, sensorSize: model.sensorSize)
        XCTAssertGreaterThan(reach, 128, "clarity's large blur reads past the 128 px margin on a 24 MP frame")

        model.zoomToActualSize()
        XCTAssertNotNil(model.tile)
        let sensor = CGRect(origin: .zero, size: model.sensorSize)
        for step in 0..<6 {
            model.pan(by: CGSize(width: -40, height: step.isMultiple(of: 2) ? -25 : 0))
            model.rerenderForViewport()
            // Whatever the tile on hand shows of the view is at least the
            // reach inside the render's edge.
            XCTAssertTrue(model.tileCoversView)
            let usable = model.tileHealedCoverage.insetBy(dx: reach, dy: reach)
            XCTAssertTrue(usable.contains(model.visibleSensorRect.intersection(sensor)),
                          "step \(step): the view reaches the clamped band")
        }
    }
}
