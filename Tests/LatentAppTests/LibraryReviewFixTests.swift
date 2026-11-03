import XCTest
import AppKit
import Combine
@testable import Catalog
import PixelEngine
@testable import latent_app

/// Regression tests for the library group's review findings: the grid, the
/// export queue, the status bar, quitting and the sidebar.
@MainActor
final class LibraryReviewFixTests: XCTestCase {
    private static func record(id: Int64, relPath: String) -> ImageRecord {
        ImageRecord(id: id, relPath: relPath, preservedName: nil, size: 1, mtime: 0, xxhash: Data(count: 8),
                    captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil, shutter: nil, aperture: nil,
                    focal: nil, width: nil, height: nil, orientation: nil, rating: 0, label: nil, flag: 0,
                    sidecarMtime: nil, thumbKey: nil)
    }

    // MARK: Held keys (#111)

    /// A held \, R, Z, Space or F used to toggle at the key-repeat rate and
    /// end in whichever state the last repeat left.
    func testTogglingCommandsDoNotRepeatWhileHeld() {
        for command: KeyCommand in [.beforeAfter, .crop, .heal, .redEye, .dust, .touchUp, .toggleZoom,
                                    .toggleLoupe, .fullScreenImage, .library, .develop, .openSelection,
                                    .pick, .rate(3), .deleteHeal] {
            XCTAssertFalse(command.repeatsWhileHeld, "\(command)")
        }
        for command: KeyCommand in [.step(1), .step(-1), .panImage(.left), .toolSize(1), .zoomIn, .zoomOut] {
            XCTAssertTrue(command.repeatsWhileHeld, "\(command)")
        }
    }

    // MARK: Stale loads (#23)

    /// A held arrow key starts a load per image passed; only the one still
    /// selected when its edit has been read may open (and decode).
    func testOnlyTheLoadStillSelectedOpens() {
        XCTAssertFalse(ContentView.loadIsCurrent(recordID: 1, selectedImageID: 2, catalogUnchanged: true))
        XCTAssertTrue(ContentView.loadIsCurrent(recordID: 2, selectedImageID: 2, catalogUnchanged: true))
        XCTAssertFalse(ContentView.loadIsCurrent(recordID: 2, selectedImageID: 2, catalogUnchanged: false))
        XCTAssertFalse(ContentView.loadIsCurrent(recordID: nil, selectedImageID: nil, catalogUnchanged: true))
    }

    // MARK: The GPU slot (#53, #54)

    func testExportRefusedWhileAnotherJobHoldsTheSlotSaysSo() async throws {
        let gpu: GPUContext
        do { gpu = try await GPUContext.shared() } catch { throw XCTSkip("No GPU: \(error)") }
        let queue = ExportQueue(outputJobs: OutputJobs())
        XCTAssertTrue(queue.claimSlot())
        XCTAssertTrue(queue.isGPUBusy, "the grid's Export… and the sheet's button follow this")
        queue.start(records: [Self.record(id: 1, relPath: "A.NEF")], library: Library(), preset: ExportPreset(),
                    destination: FileManager.default.temporaryDirectory, gpu: gpu)
        XCTAssertFalse(queue.isRunning)
        XCTAssertEqual(queue.summary, ExportQueue.busyRefusal, "refused out loud, not silently")
        queue.releaseSlot()
        XCTAssertFalse(queue.isGPUBusy)
    }

    func testPrintsAndContactSheetsTakeTurnsWithTheQueue() {
        let jobs = OutputJobs()
        let queue = ExportQueue(outputJobs: jobs)
        for kind: OutputJobs.Kind in [.print, .contactSheet] {
            let id = jobs.begin(kind, name: "Sheet")
            XCTAssertTrue(queue.isGPUBusy, "\(kind)")
            XCTAssertFalse(queue.claimSlot(), "no merge or dust job alongside a \(kind)")
            jobs.end(id)
            XCTAssertFalse(queue.isGPUBusy)
        }

        var state = CommandState()
        state.mode = .library
        state.editorReady = true
        state.hasSelection = true
        state.selectionCount = 2
        XCTAssertTrue(state.isEnabled(.print))
        XCTAssertTrue(state.isEnabled(.contactSheet))
        XCTAssertTrue(state.isEnabled(.export))
        var exporting = state
        exporting.exportQueueRunning = true
        XCTAssertFalse(exporting.isEnabled(.print))
        XCTAssertFalse(exporting.isEnabled(.contactSheet))
        var merging = state
        merging.photoMergeRunning = true
        XCTAssertFalse(merging.isEnabled(.print))
        var printing = state
        printing.outputJobRunning = true
        XCTAssertFalse(printing.isEnabled(.export))
    }

    // MARK: Files changing under a job (#87)

    func testFilesDontChangeWhileAPrintOrMergeReadsThem() {
        XCTAssertTrue(ContentView.canChangeFiles(fileOperationBusy: false, exportRunning: false, outputJobRunning: false))
        XCTAssertFalse(ContentView.canChangeFiles(fileOperationBusy: false, exportRunning: false, outputJobRunning: true))
        XCTAssertFalse(ContentView.canChangeFiles(fileOperationBusy: false, exportRunning: true, outputJobRunning: false))
        XCTAssertFalse(ContentView.canChangeFiles(fileOperationBusy: true, exportRunning: false, outputJobRunning: false))
    }

    // MARK: Open File… (#92)

    /// The file chosen with Open File… must survive the switch to Develop
    /// rather than be replaced by the grid's selection.
    func testOpenFileKeepsTheFileItOpened() {
        XCTAssertFalse(ContentView.modeChangeLoadsSelection(editorImageID: nil, selectedImageID: 5,
                                                            keepingOpenedFile: true))
        XCTAssertTrue(ContentView.modeChangeLoadsSelection(editorImageID: nil, selectedImageID: 5,
                                                           keepingOpenedFile: false))
        XCTAssertFalse(ContentView.modeChangeLoadsSelection(editorImageID: 5, selectedImageID: 5,
                                                            keepingOpenedFile: false))
    }

    // MARK: Same file names in included subfolders (#110)

    func testTheEditorIsMatchedByCatalogIDNotFileName() {
        let other = Self.record(id: 2, relPath: "2025/DSC_0001.NEF")
        XCTAssertFalse(ContentView.editorHolds(other, catalogImageID: 1, imageTitle: "DSC_0001.NEF"),
                       "a namesake in another subfolder is not the editor's photo")
        XCTAssertTrue(ContentView.editorHolds(other, catalogImageID: 2, imageTitle: "DSC_0001.NEF"))
        XCTAssertTrue(ContentView.editorHolds(other, catalogImageID: nil, imageTitle: "DSC_0001.NEF"),
                      "a file opened on its own has only its name")
    }

    // MARK: The Library's status bar (#173)

    func testGridOutcomesShowInTheLibraryStatusBar() async throws {
        XCTAssertEqual(ContentView.libraryStatusText(handOffNotice: nil, gridNotice: nil, folderStatus: "12 images"),
                       "12 images")
        let pasted = "Pasted settings to 3 images · skipped 1 with unreadable edits: B.NEF"
        XCTAssertEqual(ContentView.libraryStatusText(handOffNotice: nil, gridNotice: pasted, folderStatus: "12 images"),
                       pasted)

        let notice = GridNotice(shownFor: .milliseconds(50))
        notice.post(pasted)
        XCTAssertEqual(notice.text, pasted)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNil(notice.text, "the folder's status comes back")
    }

    // MARK: Survey and Compare panes (#179)

    func testAPanesFailuresReachTheStatusBar() {
        let pane = EditorModel()
        var seen: [String] = []
        let watching = pane.paneProblems.sink { seen.append($0) }
        pane.status = "NIKON D750 · 6032×4032"
        pane.lastError = "Reading the stored edit for A.NEF failed: bad JSON"
        pane.status = "Could not open: unreadable"
        XCTAssertEqual(seen, ["Reading the stored edit for A.NEF failed: bad JSON", "Could not open: unreadable"])
        watching.cancel()
    }

    func testSurveyPassesPaneFailuresOn() throws {
        let survey = SurveyModel(policy: MemoryPolicy(physicalMemory: 32 << 30))
        var problems: [String] = []
        survey.onPaneProblem = { problems.append($0) }
        let panes = try XCTUnwrap(SurveyPanes(selected: [1, 2], primary: 1, order: [1, 2]))
        survey.show(panes) { _, _ in }
        let unfocused = try XCTUnwrap(survey.model(for: 2))
        unfocused.lastError = "Reading the stored edit for B.NEF failed: bad JSON"
        XCTAssertEqual(problems, ["Reading the stored edit for B.NEF failed: bad JSON"])
        survey.closeAll()
    }

    // MARK: The export sheet's starting folder (#207)

    func testDefaultExportFolderWinsOverTheLastOneChosen() {
        let a = URL(fileURLWithPath: "/tmp/A", isDirectory: true)
        let b = URL(fileURLWithPath: "/tmp/B", isDirectory: true)
        var askedForLastUsed = false
        XCTAssertEqual(ExportSheet.initialDestination(preference: b, lastUsed: { askedForLastUsed = true; return a }), b)
        XCTAssertFalse(askedForLastUsed, "the bookmark isn't resolved when it isn't used")
        XCTAssertEqual(ExportSheet.initialDestination(preference: nil, lastUsed: { a }), a)
    }

    // MARK: Quitting (#180)

    func testASaveThatFailsWhileQuittingIsCaught() {
        let library = Library()
        library.lastError = "An earlier failure, already shown"
        let watch = QuitSaveWatch([library])
        XCTAssertTrue(watch.failures.isEmpty, "an earlier failure is not the quit's")
        library.lastError = "Saving the edit failed: disk full"
        XCTAssertEqual(watch.failures, ["Saving the edit failed: disk full"])
        watch.restoreEarlierErrors()
        XCTAssertEqual(library.lastError, "Saving the edit failed: disk full", "the newer failure stays shown")

        let quiet = Library()
        quiet.lastError = "Earlier"
        let clean = QuitSaveWatch([quiet])
        XCTAssertTrue(clean.failures.isEmpty)
        clean.restoreEarlierErrors()
        XCTAssertEqual(quiet.lastError, "Earlier", "kept working: the earlier message comes back")
    }

    // MARK: The filter bar (#192)

    /// The pickers' lists are worked out with the image list, not on every
    /// change the Library publishes (each thumbnail finishing, say).
    func testFilterOptionsAreNotRebuiltForUnrelatedChanges() async throws {
        let library = Library()
        let options = FilterOptions()
        options.attach(to: library)
        let rebuilt = options.rebuildCount
        for _ in 0..<100 { library.objectWillChange.send() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(options.rebuildCount, rebuilt)
        XCTAssertEqual(options.cameras, library.availableCameras)
        XCTAssertEqual(options.keywords, library.availableKeywords)
    }

    // MARK: Favourites at launch (#211)

    /// Resolving a favourite on a share that stopped answering must not
    /// hold up the store being made: rows come back at once, not yet
    /// available, and turn available when the resolve returns.
    func testFavouritesResolveOffTheMainThread() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("latent-fav-\(UUID().uuidString)",
                                                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bookmark = try XCTUnwrap(BookmarkStore.bookmark(for: folder))
        let suite = "latent-fav-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([bookmark], forKey: BookmarkStore.favouriteFolders)

        let gate = DispatchSemaphore(value: 0)
        let ranOnMain = LockedFlag()
        let started = Date()
        let store = FavouriteFolders(defaults: defaults, resolve: { _ in
            if Thread.isMainThread { ranOnMain.set() }
            gate.wait()
            return (folder, false)
        }, watchesVolumes: false)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "made without waiting for the resolve")
        XCTAssertEqual(store.folders.count, 1)
        XCTAssertEqual(store.folders.first?.isAvailable, false, "not connected until resolved")

        gate.signal()
        await store.restoring?.value
        XCTAssertEqual(store.folders.first?.isAvailable, true)
        XCTAssertFalse(ranOnMain.value)
    }

    // MARK: The export loop's disk calls (#61)

    func testExportSettlesNamesAndMakesFoldersOffTheMainThread() async throws {
        let destination = URL(fileURLWithPath: "/tmp/latent-nowhere", isDirectory: true)
        var options = ExportPreset().planOptions(catalogName: "Shoot")
        options.dateSubfolders = true
        let calledOnMain = LockedFlag()
        let calls = LockedFlag()
        let probe = ExportBatchPlanner.Probe(item: { _ in
            if Thread.isMainThread { calledOnMain.set() }
            calls.set()
            return nil
        }, isCaseSensitive: { _ in false })
        let plan = ExportBatchPlanner.plan([Self.record(id: 1, relPath: "A.NEF")], into: destination,
                                           options: options, probe: .nothingOnDisk)
        let made = LockedFlag()
        let settled = await ExportQueue.settle(plan, index: 0, makeFolder: true, probe: probe, makeDirectory: { _ in
            if Thread.isMainThread { calledOnMain.set() }
            made.set()
        })
        XCTAssertEqual(settled.output.action, .write)
        XCTAssertNil(settled.folderError)
        XCTAssertTrue(calls.value)
        XCTAssertTrue(made.value, "the date folder is made")
        XCTAssertFalse(calledOnMain.value, "neither the probe nor the folder runs on the main thread")
    }

    // MARK: The sidebar's favourite names (#200)

    func testFavouriteNamesAreReadOffTheMainThread() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("latent-side-\(UUID().uuidString)",
                                                                                    isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let controller = FolderOutlineController()
        let calledOnMain = LockedFlag()
        let called = LockedFlag()
        controller.displayName = { url in
            if Thread.isMainThread { calledOnMain.set() }
            called.set()
            return url.lastPathComponent
        }
        controller.setFavourites([FavouriteFolder(url: folder, bookmark: Data(), isAvailable: true)])
        for _ in 0..<50 where !called.value { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(called.value, "the Finder name is still looked up")
        XCTAssertFalse(calledOnMain.value)
    }
}

/// A flag set from any thread.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false
    func set() { lock.withLock { isSet = true } }
    var value: Bool { lock.withLock { isSet } }
}
