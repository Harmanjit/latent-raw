import XCTest
import AppKit
import PixelEngine
import MLKit
@testable import latent_app

/// Models in the app (docs/Retouch.md §5): what the Add menu and the mask
/// rows list, what Settings › AI › Models says, what a rerun rewrites,
/// and how exports, prints and contact sheets report a stand-in model.
/// The registry is a fixture in a temporary folder: two subject models
/// (one bundled, one installed), the bundled click-to-select model, and
/// catalogue rows for the ones this Mac lacks.
@MainActor
final class ModelMenuTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    nonisolated(unsafe) private var bundled: URL!
    nonisolated(unsafe) private var external: URL!
    nonisolated(unsafe) private var catalogue: URL!
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suite: String!

    override func setUpWithError() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appendingPathComponent("latent-model-menus-\(UUID().uuidString)")
        bundled = root.appendingPathComponent("bundled")
        external = root.appendingPathComponent("external")
        catalogue = bundled.appendingPathComponent("ModelCatalog.json")
        try fm.createDirectory(at: bundled, withIntermediateDirectories: true)
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        suite = "latent-model-menus-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixture

    private static func json(id: String, name: String, kind: String, sizeMB: Int = 100, row: Bool = false,
                             licence: String = "MIT", commercialUse: Bool = true) -> String {
        let hash = row ? "null" : "\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\""
        let packages = kind == "promptedSegmentation"
            ? ["imageEncoder", "promptEncoder", "maskDecoder"].map { "{\"name\": \"\($0).mlpackage\", \"role\": \"\($0)\", \"sha256\": \(hash)}" }
            : ["{\"name\": \"A.mlpackage\", \"sha256\": \(hash)}"]
        return """
        {"id": "\(id)", "displayName": "\(name)", "purpose": "Testing", "version": 1, "kind": "\(kind)",
         "licence": {"name": "\(licence)", "url": "https://example.org/L", "commercialUse": \(commercialUse)},
         "sourceURL": "https://example.org/\(id)", "sizeMB": \(sizeMB), "inputSize": 64,
         "packages": [\(packages.joined(separator: ", "))]}
        """
    }

    private func addBundled(_ id: String, name: String, kind: String, sizeMB: Int = 100) throws {
        try Self.json(id: id, name: name, kind: kind, sizeMB: sizeMB)
            .write(to: bundled.appendingPathComponent("\(id).model.json"), atomically: true, encoding: .utf8)
    }

    private func addInstalled(_ id: String, name: String, kind: String, sizeMB: Int = 100) throws {
        let dir = external.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.json(id: id, name: name, kind: kind, sizeMB: sizeMB)
            .write(to: dir.appendingPathComponent("\(id).model.json"), atomically: true, encoding: .utf8)
    }

    private func writeCatalogue(_ rows: [(id: String, name: String, kind: String)]) throws {
        let json = "[" + rows.map { Self.json(id: $0.id, name: $0.name, kind: $0.kind, sizeMB: 446, row: true) }
            .joined(separator: ",") + "]"
        try json.write(to: catalogue, atomically: true, encoding: .utf8)
    }

    /// The plan's cast: BiRefNet Lite and SAM 2.1 Small bundled, U²-Net
    /// added, BiRefNet General and SAM 2.1 Large in the catalogue only.
    private func fixture() throws -> ModelRegistry {
        try addBundled("birefnet-lite", name: "BiRefNet Lite", kind: "subjectSegmentation", sizeMB: 103)
        try addBundled("sam2.1-small", name: "SAM 2.1 Small", kind: "promptedSegmentation", sizeMB: 94)
        try addBundled("nafnet-sidd-w32", name: "NAFNet SIDD width 32", kind: "denoise", sizeMB: 59)
        try addInstalled("u2net", name: "U²-Net", kind: "subjectSegmentation", sizeMB: 88)
        try writeCatalogue([("birefnet-general", "BiRefNet General", "subjectSegmentation"),
                            ("sam2.1-large", "SAM 2.1 Large", "promptedSegmentation")])
        return ModelRegistry(bundled: bundled, external: external, catalogue: catalogue, defaults: defaults)
    }

    // MARK: - The Add menu

    /// Subject lists the installed subject models with the default first
    /// (the preference, when installed); Click to Select likewise; a
    /// catalogue row is never offered.
    func testAddMenuListsInstalledModelsDefaultFirst() throws {
        let registry = try fixture()
        XCTAssertEqual(ModelMenus.choices(kind: .subjectSegmentation, registry: registry).map(\.id),
                       ["birefnet-lite", "vision.foregroundInstance", "u2net"])
        XCTAssertEqual(ModelMenus.choices(kind: .promptedSegmentation, registry: registry).map(\.id), ["sam2.1-small"])

        defaults.set("u2net", forKey: ModelRegistry.subjectPreferenceKey)
        XCTAssertEqual(ModelMenus.choices(kind: .subjectSegmentation, registry: registry).map(\.id),
                       ["u2net", "vision.foregroundInstance", "birefnet-lite"])

        // A preference naming a model that is not installed falls back.
        defaults.set("birefnet-general", forKey: ModelRegistry.subjectPreferenceKey)
        XCTAssertEqual(ModelMenus.choices(kind: .subjectSegmentation, registry: registry).first?.id, "birefnet-lite")
    }

    /// The mask row names its model; Menu("Model") offers the others of
    /// that kind, never the one making the mask now.
    func testMaskRowsNameTheirModelAndOfferTheOthers() throws {
        let registry = try fixture()
        let subject = MaskShape.ai(kind: "subject", modelVersion: "birefnet-lite@1")
        XCTAssertEqual(ModelMenus.rowTitle(for: subject, registry: registry), "Subject · BiRefNet Lite")
        XCTAssertEqual(ModelMenus.alternatives(for: subject, registry: registry).map(\.id),
                       ["vision.foregroundInstance", "u2net"])
        XCTAssertNil(ModelMenus.missingSentence(for: subject, registry: registry))

        let legacy = MaskShape.ai(kind: "subject", modelVersion: "vision.foregroundInstance.1")
        XCTAssertEqual(ModelMenus.rowTitle(for: legacy, registry: registry), "Subject · Apple Vision")
        XCTAssertNil(ModelMenus.missingSentence(for: legacy, registry: registry))

        let points = [MaskPromptPoint(x: 0.5, y: 0.5, foreground: true), MaskPromptPoint(x: 0.6, y: 0.5, foreground: true),
                      MaskPromptPoint(x: 0.4, y: 0.5, foreground: false)]
        let prompted = MaskShape.prompted(points: points, modelVersion: "sam2.1-small@1")
        XCTAssertEqual(ModelMenus.promptedRowText(for: prompted, status: "Image encoded in 640 ms", registry: registry),
                       "SAM 2.1 Small · 3 points · Image encoded in 640 ms")
        XCTAssertEqual(ModelMenus.promptedRowText(for: .prompted(points: [], modelVersion: "sam2.1-small@1"), status: "",
                                                  registry: registry),
                       "SAM 2.1 Small · Click the thing you want. Option-click to exclude something.")
        XCTAssertTrue(ModelMenus.alternatives(for: prompted, registry: registry).isEmpty, "Small is the only one installed")
    }

    /// A mask whose model this Mac lacks says so, with what stands in: a
    /// subject model gives way to Apple Vision, a click-to-select model to
    /// the default one. What the registry cannot name is shown as stored.
    func testMissingModelSentence() throws {
        let registry = try fixture()
        let general = MaskShape.ai(kind: "subject", modelVersion: "birefnet-general@1")
        XCTAssertEqual(ModelMenus.missingSentence(for: general, registry: registry),
                       "BiRefNet General is not installed — shown with Apple Vision instead.")
        XCTAssertEqual(ModelMenus.rowTitle(for: general, registry: registry), "Subject · Apple Vision")
        XCTAssertEqual(ModelMenus.missingEntry(for: general, registry: registry)?.id, "birefnet-general", "Get… has a page")

        let large = MaskShape.prompted(points: [MaskPromptPoint(x: 0.5, y: 0.5, foreground: true)],
                                       modelVersion: "sam2.1-large@1")
        XCTAssertEqual(ModelMenus.missingSentence(for: large, registry: registry),
                       "SAM 2.1 Large is not installed — shown with SAM 2.1 Small instead.")
        XCTAssertEqual(ModelMenus.rowTitle(for: large, registry: registry), "SAM 2.1 Small")

        let garbage = MaskShape.ai(kind: "subject", modelVersion: "test")
        XCTAssertEqual(ModelMenus.missingSentence(for: garbage, registry: registry),
                       "test is not installed — shown with Apple Vision instead.")
        XCTAssertNil(ModelMenus.missingEntry(for: garbage, registry: registry), "nothing to get")

        // The bundled class model or its estimate stands in silently, as
        // the 0.9.0 beta did; only a real, missing class model is named.
        XCTAssertNil(ModelMenus.missingSentence(for: .ai(kind: "sky", modelVersion: "latent.skyHeuristic@1"), registry: registry))
        XCTAssertNil(ModelMenus.missingSentence(for: .ai(kind: "sky", modelVersion: "segformer-b2-ade20k-512.1"), registry: registry))
        XCTAssertNil(ModelMenus.missingSentence(for: .linear(start: .zero, end: .one), registry: registry))
    }

    // MARK: - Settings › AI › Models

    /// The row as VoiceOver reads it.
    func testSpokenModelWording() {
        XCTAssertEqual(SpokenText.model(name: "BiRefNet Lite", kind: .subjectSegmentation, licence: "MIT", commercialUse: true,
                                        sizeMB: 103, status: .bundled, isDefault: true),
                       "BiRefNet Lite, subject, MIT licence, 103 megabytes, bundled, default")
        XCTAssertEqual(SpokenText.model(name: "IS-Net", kind: .subjectSegmentation, licence: "Apache-2.0 code, DIS5K research-only",
                                        commercialUse: false, sizeMB: 88, status: .notInstalled, isDefault: false),
                       "IS-Net, subject, Apache-2.0 code, DIS5K research-only licence, research use only, 88 megabytes, not installed")
        XCTAssertEqual(SpokenText.model(name: "SAM 2.1 Large", kind: .promptedSegmentation, licence: "Apache-2.0",
                                        commercialUse: true, sizeMB: 457, status: .installed, isDefault: false),
                       "SAM 2.1 Large, click to select, Apache-2.0 licence, 457 megabytes, installed")
        XCTAssertEqual(SpokenText.model(name: "Apple Vision", kind: .subjectSegmentation, licence: "Part of macOS",
                                        commercialUse: true, sizeMB: 0, status: .builtIn, isDefault: false),
                       "Apple Vision, subject, Part of macOS licence, built in")
    }

    /// The rows: every kind but denoise, in the registry's order, the
    /// default of each kind marked; Use records the choice and re-marks;
    /// removing the default says what stands in now.
    func testSettingsRowsAndChoices() throws {
        let registry = try fixture()
        var chosen: [(ModelManifest.Kind, String)] = []
        let model = ModelSettingsModel(registry: registry) { kind, id in
            chosen.append((kind, id))
            let key = kind == .promptedSegmentation ? ModelRegistry.promptedPreferenceKey : ModelRegistry.subjectPreferenceKey
            self.defaults.set(id, forKey: key)
        }
        XCTAssertEqual(model.rows.map(\.id), ["vision.foregroundInstance", "birefnet-lite", "sam2.1-small", "u2net",
                                             "birefnet-general", "sam2.1-large"])
        XCTAssertEqual(model.rows.filter(\.isDefault).map(\.id), ["birefnet-lite", "sam2.1-small"])
        XCTAssertEqual(model.rows.map { ModelSettingsModel.status($0.entry.status) },
                       ["Built in", "Bundled", "Bundled", "Installed", "Not installed", "Not installed"])
        XCTAssertEqual(model.rows.map { ModelSettingsModel.canUse($0) }, [true, false, false, true, false, false])

        let u2net = try XCTUnwrap(model.rows.first { $0.id == "u2net" }?.entry)
        model.use(u2net)
        XCTAssertEqual(chosen.map(\.1), ["u2net"])
        XCTAssertEqual(model.rows.filter(\.isDefault).map(\.id), ["sam2.1-small", "u2net"])

        // A catalogue row cannot be used; Apple Vision can.
        model.use(try XCTUnwrap(model.rows.first { $0.id == "birefnet-general" }?.entry))
        XCTAssertEqual(chosen.count, 1)

        // Removing the default: the folder goes, the preference follows
        // the fallback, and the message says so.
        model.remove(u2net)
        XCTAssertFalse(FileManager.default.fileExists(atPath: external.appendingPathComponent("u2net").path))
        XCTAssertEqual(chosen.map(\.1), ["u2net", "birefnet-lite"])
        XCTAssertEqual(model.message, "Removed U²-Net; new subject masks use BiRefNet Lite.")
        XCTAssertEqual(model.rows.map(\.id), ["vision.foregroundInstance", "birefnet-lite", "sam2.1-small",
                                             "birefnet-general", "sam2.1-large"])
        XCTAssertEqual(ModelSettingsModel.removedMessage(name: "MODNet", wasDefault: false, kind: .subjectSegmentation,
                                                         fallback: nil), "Removed MODNet.")
        XCTAssertEqual(ModelSettingsModel.removedMessage(name: "SAM 2.1 Large", wasDefault: true,
                                                         kind: .promptedSegmentation, fallback: "SAM 2.1 Small"),
                       "Removed SAM 2.1 Large; new click-to-select masks use SAM 2.1 Small.")
        XCTAssertEqual(ModelSettingsModel.purpose(.promptedSegmentation), "Click to select")
        XCTAssertEqual(ModelSettingsModel.purpose(.semanticSegmentation), "Classes")
    }

    /// Add Model… refuses what is not a model with the importer's sentence
    /// and leaves nothing behind.
    func testAddingSomethingElseIsRefusedInASentence() async throws {
        let registry = try fixture()
        let model = ModelSettingsModel(registry: registry) { _, _ in }
        let folder = root.appendingPathComponent("not-a-model")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await model.add(from: folder)
        XCTAssertEqual(model.message, "The folder has no .model.json manifest, so the model was not added.")
        XCTAssertTrue(model.messageIsError)
        XCTAssertNil(model.importing)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path).sorted(), ["u2net"])
        XCTAssertNil(ModelSettingsModel.manifestName(at: folder))
        XCTAssertEqual(ModelSettingsModel.manifestName(at: external.appendingPathComponent("u2net")), "U²-Net")
        XCTAssertEqual(ModelSettingsModel.manifestName(at: external.appendingPathComponent("u2net/A.mlpackage")), "U²-Net")
    }

    // MARK: - Rerun

    /// Choosing another model for a mask rewrites the stored version and
    /// drops the pixels, as one undoable parameter change; the new
    /// pixels come when the model has run.
    func testRerunRewritesTheModelVersionAndClearsTheBitmap() async throws {
        let url = try TestAssets.d750URL()
        _ = try await GPUContext.shared()
        let model = EditorModel()
        // A catalog id: history steps are recorded as edits are saved.
        model.open(url: url, catalogImageID: 1)
        XCTAssertTrue(model.hasImage)
        model.viewportDidResize(to: CGSize(width: 1200, height: 800))
        let session = try XCTUnwrap(model.session)

        let local = LocalAdjustment(name: "Subject", shape: .ai(kind: "subject", modelVersion: "birefnet-lite@1"))
        model.parameters.locals = [local]
        model.flushPendingSave()
        session.setAIMask(MaskBitmap(width: 1, height: 1, data: [255]), forLocal: local.id)
        XCTAssertTrue(session.hasAIMask(forLocal: local.id))
        XCTAssertTrue(model.canUndo, "adding the mask was a step")

        let vision = try XCTUnwrap(ModelRegistry.shared.entry(id: ModelRegistry.builtInSubjectID))
        model.rerunMask(at: 0, with: vision)
        guard case .ai(let kind, let version) = model.parameters.locals[0].shape else { return XCTFail("shape changed") }
        XCTAssertEqual(kind, "subject")
        XCTAssertEqual(version, "vision.foregroundInstance@1")
        XCTAssertEqual(model.parameters.locals[0].id, local.id, "the same mask, made again")
        XCTAssertFalse(session.hasAIMask(forLocal: local.id), "the old pixels are gone until Vision answers")
        XCTAssertTrue(model.generatingMasks.contains(local.id))
        XCTAssertTrue(model.status.hasPrefix("Generating subject mask with Apple Vision"), model.status)
        model.flushPendingSave()
        XCTAssertTrue(model.canUndo, "the rerun is a step of its own")
        // The new model's pixels land (stood in for): Undo names the old
        // model again, so they go and its mask is made again.
        session.setAIMask(MaskBitmap(width: 1, height: 1, data: [255]), forLocal: local.id)
        model.undo()
        guard case .ai(_, let before) = model.parameters.locals[0].shape else { return XCTFail("shape changed") }
        XCTAssertEqual(before, "birefnet-lite@1", "undo brings the old model back")
        XCTAssertFalse(session.hasAIMask(forLocal: local.id), "the other model's pixels are gone")
        XCTAssertTrue(model.generatingMasks.contains(local.id))
        XCTAssertTrue(model.status.hasPrefix("Generating subject mask with"), model.status)
        session.setAIMask(MaskBitmap(width: 1, height: 1, data: [255]), forLocal: local.id)
        model.redo()
        guard case .ai(_, let after) = model.parameters.locals[0].shape else { return XCTFail("shape changed") }
        XCTAssertEqual(after, "vision.foregroundInstance@1")
        XCTAssertFalse(session.hasAIMask(forLocal: local.id), "redo drops them the same way")
        // Out of range, or a hand-drawn mask: nothing happens.
        model.rerunMask(at: 5, with: vision)
        model.parameters.locals.append(LocalAdjustment(name: "G", shape: .linear(start: .zero, end: .one)))
        model.rerunMask(at: 1, with: vision)
        XCTAssertEqual(model.parameters.locals[1].shape, .linear(start: .zero, end: .one))
        model.closeImage()
        XCTAssertTrue(model.promptSessions.isEmpty)
        XCTAssertTrue(model.promptStatus.isEmpty)
    }

    // MARK: - Export, print and contact sheet reporting

    func testExportNoteWording() throws {
        let registry = try fixture()
        XCTAssertEqual(MaskSubstitutions.summarySuffix(count: 0), "")
        XCTAssertEqual(MaskSubstitutions.summarySuffix(count: 2), " · 2 with substituted masks")
        XCTAssertEqual(MaskSubstitutions.exportNote(name: "DSC_0107.NEF", missing: ["BiRefNet General"], registry: registry),
                       "DSC_0107.NEF used Apple Vision because BiRefNet General is not installed")
        XCTAssertEqual(MaskSubstitutions.exportNote(name: "DSC_0108.NEF", missing: ["SAM 2.1 Large"], registry: registry),
                       "DSC_0108.NEF used SAM 2.1 Small because SAM 2.1 Large is not installed")
        XCTAssertEqual(MaskSubstitutions.exportNote(name: "DSC_0109.NEF", missing: ["BiRefNet General", "SAM 2.1 Large"],
                                                    registry: registry),
                       "DSC_0109.NEF used stand-in models because BiRefNet General and SAM 2.1 Large are not installed")
        XCTAssertEqual(MaskSubstitutions.exportNote(name: "DSC_0110.NEF", missing: ["test"], registry: registry),
                       "DSC_0110.NEF used stand-in models because test is not installed")

        XCTAssertNil(MaskSubstitutions.pageSentence(photos: 0, missing: [], registry: registry))
        XCTAssertEqual(MaskSubstitutions.pageSentence(photos: 2, missing: ["BiRefNet General"], registry: registry),
                       "2 photos used Apple Vision because BiRefNet General is not installed")
        XCTAssertEqual(MaskSubstitutions.pageSentence(photos: 1, missing: ["BiRefNet General"], registry: registry),
                       "1 photo used Apple Vision because BiRefNet General is not installed")

        let substitutions = ["DSC_0107.NEF": ["BiRefNet General"], "DSC_0108.NEF": ["BiRefNet General"]]
        XCTAssertEqual(PrintSession.printedMessage(unrendered: [], substitutions: substitutions, registry: registry),
                       "2 photos used Apple Vision because BiRefNet General is not installed")
        XCTAssertEqual(PrintSession.printedMessage(unrendered: ["missing-a"], substitutions: substitutions, registry: registry),
                       "missing-a couldn’t be rendered and printed as an empty cell. "
                       + "2 photos used Apple Vision because BiRefNet General is not installed")
        XCTAssertNil(PrintSession.printedMessage(unrendered: [], substitutions: [:], registry: registry))
        XCTAssertEqual(ContactSheetPresenter.savedMessage(fileName: "sheet.pdf", unrendered: [], substitutions: substitutions,
                                                          registry: registry),
                       "Saved “sheet.pdf”. 2 photos used Apple Vision because BiRefNet General is not installed")
        XCTAssertEqual(ContactSheetPresenter.savedMessage(fileName: "sheet.pdf", unrendered: ["a"], substitutions: [:],
                                                          registry: registry),
                       "Saved “sheet.pdf”; a couldn’t be rendered")
    }

    /// A page renderer keeps what each render reported, by photo name,
    /// and only for photos that needed a stand-in.
    func testSheetRendererCollectsSubstitutionsPerPhoto() throws {
        let log = MaskSubstitutionLog()
        log.record("clean.NEF", missing: [])
        log.record("DSC_0107.NEF", missing: ["BiRefNet General"])
        let renderer = SheetRenderer(cache: SheetImageCache(byteBudget: 1 << 20), render: { _, _ in nil },
                                     substitutions: log)
        XCTAssertEqual(renderer.maskSubstitutions, ["DSC_0107.NEF": ["BiRefNet General"]])
    }
}
