import XCTest
import SwiftUI
import ImageIO
import Metal
import AVFoundation
@testable import latent_app
@testable import Catalog
import PixelEngine

@MainActor
final class SlideshowSequenceTests: XCTestCase {
    func testStepsWrapOnlyWhenLooping() {
        var looping = SlideshowSequence(count: 3, loops: true)
        XCTAssertEqual(looping.step(from: 2, by: 1), 0)
        XCTAssertEqual(looping.step(from: 0, by: -1), 2)
        looping.loops = false
        XCTAssertNil(looping.step(from: 2, by: 1))
        XCTAssertNil(looping.step(from: 0, by: -1))
        XCTAssertEqual(looping.step(from: 1, by: 1), 2)
    }

    func testFailedImagesAreSkippedBothWays() {
        var sequence = SlideshowSequence(count: 4, loops: false)
        sequence.markFailed(1)
        XCTAssertEqual(sequence.step(from: 0, by: 1), 2)
        XCTAssertEqual(sequence.step(from: 2, by: -1), 0)
        XCTAssertEqual(sequence.first(from: 1), 2)
        sequence.markFailed(0); sequence.markFailed(2); sequence.markFailed(3)
        XCTAssertFalse(sequence.hasPlayable)
        XCTAssertNil(sequence.first(from: 0))
    }

    /// One image doesn't transition into itself, looping or not.
    func testASingleImageHasNothingNext() {
        let sequence = SlideshowSequence(count: 1, loops: true)
        XCTAssertEqual(sequence.first(from: 5), 0)
        XCTAssertNil(sequence.step(from: 0, by: 1))
        XCTAssertNil(SlideshowSequence(count: 0, loops: true).first(from: 0))
    }

    private func record(_ id: Int64, _ name: String, captured: Int64? = nil, camera: String? = nil,
                        shutter: Double? = nil, aperture: Double? = nil) -> ImageRecord {
        ImageRecord(id: id, relPath: name, preservedName: nil, size: 1, mtime: 0, xxhash: Data(count: 8),
                    captureTime: captured, camera: camera, lens: nil, lensId: nil, iso: nil, shutter: shutter,
                    aperture: aperture, focal: nil, width: nil, height: nil, orientation: nil, rating: 0,
                    label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil)
    }

    func testTheShowPlaysTheSelectionOrEverythingVisible() {
        let visible = (1...5).map { record(Int64($0), "IMG_\($0).NEF") }
        var chosen = SlideshowImages.choose(visible: visible, selectedIDs: [4, 2], primary: 4)
        XCTAssertEqual(chosen.records.map(\.id), [2, 4], "in the grid's order")
        XCTAssertEqual(chosen.start, 1)
        chosen = SlideshowImages.choose(visible: visible, selectedIDs: [3], primary: 3)
        XCTAssertEqual(chosen.records.count, 5)
        XCTAssertEqual(chosen.start, 2, "from the selected image")
        chosen = SlideshowImages.choose(visible: visible, selectedIDs: [], primary: nil)
        XCTAssertEqual(chosen.start, 0)
        chosen = SlideshowImages.choose(visible: visible, selectedIDs: [9], primary: 9)
        XCTAssertEqual(chosen.start, 0, "a selected image the filter hides starts at the beginning")
    }

    func testCaptions() {
        let r = record(1, "DSC_0107.NEF", captured: 0, camera: "NIKON D750", shutter: 1.0 / 250, aperture: 4)
        XCTAssertNil(SlideshowCaptionText.text(.none, record: r))
        XCTAssertEqual(SlideshowCaptionText.text(.name, record: r), "DSC_0107.NEF")
        let dated = SlideshowCaptionText.text(.nameAndDate, record: r, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(dated, "DSC_0107.NEF  ·  " + MetadataFormat.captureTime(0, timeZone: TimeZone(identifier: "UTC")!))
        XCTAssertEqual(SlideshowCaptionText.text(.exposure, record: r), "NIKON D750  ·  \(r.exposureLine)")
        XCTAssertEqual(SlideshowCaptionText.text(.exposure, record: record(2, "scan.NEF")), "scan.NEF")
        XCTAssertEqual(SlideshowCaptionText.text(.nameAndDate, record: record(2, "scan.NEF")), "scan.NEF")
    }
}

@MainActor
final class SlideshowSettingsTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suite = ""

    override func setUp() {
        suite = "latent.tests.slideshow.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testMissingAndUnreadableFieldsFallBackAndNumbersAreClamped() throws {
        let json = #"{"interval": 500, "transition": "iris", "transitionDuration": 0.01, "loop": false, "caption": "name"}"#
        let settings = try JSONDecoder().decode(SlideshowSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.interval, 60)
        XCTAssertEqual(settings.transition, .crossFade, "a transition this version doesn't have")
        XCTAssertEqual(settings.transitionDuration, 0.3)
        XCTAssertFalse(settings.loop)
        XCTAssertEqual(settings.caption, .name)
        XCTAssertFalse(settings.hasMusic)
        XCTAssertEqual(try JSONDecoder().decode(SlideshowSettings.self, from: Data("{}".utf8)), SlideshowSettings())
    }

    func testTheStoreKeepsWhatIsSetInRange() {
        let store = SlideshowSettingsStore(defaults: defaults)
        store.settings.interval = 0
        store.settings.transition = .push
        XCTAssertEqual(store.settings.interval, 1)
        let reloaded = SlideshowSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.settings.interval, 1)
        XCTAssertEqual(reloaded.settings.transition, .push)
    }

    func testMusicNeedsSongsAndTheSwitch() {
        var settings = SlideshowSettings()
        settings.playsMusic = true
        XCTAssertFalse(settings.hasMusic)
        settings.songs = [.init(name: "Song", bookmark: Data())]
        XCTAssertTrue(settings.hasMusic)
    }
}

@MainActor
final class ExternalEditorTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suite = ""

    override func setUp() {
        suite = "latent.tests.editors.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testFileNamesNeverReplaceAnything() {
        XCTAssertEqual(ExternalEditorNaming.fileName(forSourceNamed: "DSC_0107.NEF"), "DSC_0107-Edit.tif")
        XCTAssertEqual(ExternalEditorNaming.fileName(forSourceNamed: "DSC_0107.NEF", attempt: 2), "DSC_0107-Edit-2.tif")
        XCTAssertEqual(ExternalEditorNaming.fileName(forSourceNamed: "a:b.NEF"), "a_b-Edit.tif")
        XCTAssertEqual(ExternalEditorNaming.fileName(forSourceNamed: ""), "Image-Edit.tif")
        let taken: Set = ["DSC_0107-Edit.tif", "DSC_0107-Edit-2.tif"]
        let free = ExternalEditorNaming.freeName(forSourceNamed: "DSC_0107.NEF") { taken.contains($0) }
        XCTAssertEqual(free.name, "DSC_0107-Edit-3.tif")
        XCTAssertEqual(free.attempt, 3)
        XCTAssertEqual(ExternalEditorNaming.freeName(forSourceNamed: "DSC_0107.NEF", from: 5) { _ in false }.name,
                       "DSC_0107-Edit-5.tif")
    }

    func testAddingChoosesAndRemovingFallsBackToTheSystemDefault() {
        let settings = ExternalEditorSettings(defaults: defaults)
        XCTAssertNil(settings.chosen)
        let photoshop = ExternalEditorApp(name: "Photoshop", bundleIdentifier: "com.adobe.Photoshop",
                                          path: "/Applications/Adobe Photoshop.app")
        let affinity = ExternalEditorApp(name: "Affinity Photo", bundleIdentifier: nil, path: "/Applications/Affinity Photo.app")
        XCTAssertTrue(settings.add(photoshop))
        XCTAssertTrue(settings.add(affinity))
        XCTAssertEqual(settings.chosen?.name, "Affinity Photo")
        XCTAssertFalse(settings.add(photoshop), "listed once")
        XCTAssertEqual(settings.chosen?.name, "Photoshop", "adding again chooses it")

        let reloaded = ExternalEditorSettings(defaults: defaults)
        XCTAssertEqual(reloaded.apps.map(\.name), ["Photoshop", "Affinity Photo"])
        XCTAssertEqual(reloaded.chosenID, "com.adobe.Photoshop")
        reloaded.remove(id: "com.adobe.Photoshop")
        XCTAssertNil(reloaded.chosen)
        XCTAssertEqual(ExternalEditorSettings(defaults: defaults).apps.map(\.id), ["/Applications/Affinity Photo.app"])
    }

    func testAnApplicationIsRecognisedByItsBundle() {
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let app = ExternalEditorApp.application(at: finder, makeBookmark: false)
        XCTAssertEqual(app?.bundleIdentifier, "com.apple.finder")
        XCTAssertNil(ExternalEditorApp.application(at: URL(fileURLWithPath: "/etc/hosts"), makeBookmark: false))
    }
}

@MainActor
final class SlideshowCommandTests: XCTestCase {
    func testSlideshowNeedsImagesAndTheGPU() {
        var state = CommandState()
        XCTAssertFalse(state.isEnabled(.slideshow))
        state.hasVisibleImages = true
        XCTAssertFalse(state.isEnabled(.slideshow), "the GPU isn't ready")
        state.editorReady = true
        XCTAssertTrue(state.isEnabled(.slideshow))
    }

    func testEditInExternalEditorNeedsAnImageAndNoExportOfIt() {
        var state = CommandState()
        state.editorReady = true
        XCTAssertFalse(state.isEnabled(.editExternally))
        state.hasSelection = true
        XCTAssertTrue(state.isEnabled(.editExternally))
        state.exportingOpenImage = true
        XCTAssertFalse(state.isEnabled(.editExternally))
    }

    func testKeys() throws {
        let slideshow = try XCTUnwrap(Shortcuts.shortcut(for: .slideshow))
        XCTAssertEqual(slideshow.glyphs, "⌘Return")
        XCTAssertEqual(slideshow.keyEquivalent, .return)
        XCTAssertFalse(slideshow.isBare)
        XCTAssertEqual(try XCTUnwrap(Shortcuts.shortcut(for: .editExternally)).glyphs, "⌘E")
        XCTAssertEqual(SlideshowControlBar.spoken("Pause (Space)"), "Pause")
    }
}

@MainActor
final class ExternalEditorHandOffTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suite = ""
    nonisolated(unsafe) private var folder: URL!

    override func setUp() {
        suite = "latent.tests.handoff.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("latent-handoff-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor private final class RecordingOpener: ApplicationOpening {
        var opened: [(file: URL, app: URL?)] = []
        func open(_ file: URL, with app: URL?, completion: @escaping @MainActor (Error?) -> Void) {
            opened.append((file, app))
            completion(nil)
        }
    }

    /// The open image with its edit becomes a 16-bit Display P3 TIFF beside
    /// the file already there, and goes to the chosen application.
    func testTheOpenImageGoesToTheChosenApplicationAsANewTIFF() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))
        _ = try await GPUContext.shared()
        let model = EditorModel()
        model.open(url: url)
        XCTAssertTrue(model.hasImage)
        model.parameters.exposureEV = 0.3

        let existing = folder.appendingPathComponent("golden_nikon_d750_cc0-Edit.tif")
        try Data("keep me".utf8).write(to: existing)
        let settings = ExternalEditorSettings(defaults: defaults)
        settings.setFolder(folder)
        settings.add(ExternalEditorApp(name: "Preview", bundleIdentifier: "com.apple.Preview",
                                       path: "/System/Applications/Preview.app"))
        let opener = RecordingOpener()
        let handOff = ExternalEditorHandOff()
        handOff.settings = settings
        handOff.opener = opener
        // The folder is checked off the main thread: a share that has
        // stopped answering must not hang the app.
        let checks = ProfileLog()
        handOff.folderProblem = { url in
            checks.append(Thread.isMainThread ? "main" : url.lastPathComponent)
            return FolderAccess.problem(opening: url)
        }
        let held = ExportActivity.activeCount

        handOff.start(model: model, library: Library(), preferOpenImage: true)
        XCTAssertTrue(model.isExporting)
        XCTAssertEqual(ExportActivity.activeCount, held + 1, "the Mac stays awake for the render")
        let deadline = Date().addingTimeInterval(120)
        while opener.opened.isEmpty, model.lastError == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(model.lastError)
        XCTAssertEqual(checks.values, [folder.lastPathComponent])
        XCTAssertEqual(ExportActivity.activeCount, held)
        let sent = try XCTUnwrap(opener.opened.first)
        XCTAssertEqual(sent.file.lastPathComponent, "golden_nikon_d750_cc0-Edit-2.tif")
        XCTAssertEqual(sent.app?.path, "/System/Applications/Preview.app")
        XCTAssertFalse(model.isExporting)
        XCTAssertTrue(model.status.contains("golden_nikon_d750_cc0-Edit-2.tif"), model.status)
        XCTAssertEqual(handOff.notice, model.status)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep me")

        let source = try XCTUnwrap(CGImageSourceCreateWithURL(sent.file as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 16)
        XCTAssertEqual(image.colorSpace?.name as String?, CGColorSpace.displayP3 as String)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.tiff")
    }
}

/// The show's timing with slides the test makes and finishes when it says.
@MainActor
final class SlideshowControllerTests: XCTestCase {
    @MainActor private final class FakeSlides {
        var requested: [String] = []
        var cancelled: [String] = []
        private var waiting: [String: CheckedContinuation<SlideTexture, Error>] = [:]
        let slide: SlideTexture

        init(gpu: GPUContext) throws {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
            d.usage = .shaderRead
            slide = SlideTexture(texture: try XCTUnwrap(gpu.device.makeTexture(descriptor: d)))
        }

        func make(_ name: String) async throws -> SlideTexture {
            requested.append(name)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waiting[name] = continuation
                    }
                }
            } onCancel: {
                Task { @MainActor in self.cancel(name) }
            }
        }

        func cancel(_ name: String) {
            cancelled.append(name)
            waiting.removeValue(forKey: name)?.resume(throwing: CancellationError())
        }

        func finish(_ name: String) { waiting.removeValue(forKey: name)?.resume(returning: slide) }
        func fail(_ name: String) { waiting.removeValue(forKey: name)?.resume(throwing: CocoaError(.fileReadCorruptFile)) }
    }

    private func until(_ what: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { return XCTFail("gave up waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func records(_ count: Int) -> [ImageRecord] {
        (0..<count).map { i in
            ImageRecord(id: Int64(i), relPath: "IMG_\(i).NEF", preservedName: nil, size: 1, mtime: 0,
                        xxhash: Data(count: 8), captureTime: nil, camera: nil, lens: nil, lensId: nil, iso: nil,
                        shutter: nil, aperture: nil, focal: nil, width: nil, height: nil, orientation: nil,
                        rating: 0, label: nil, flag: 0, sidecarMtime: nil, thumbKey: nil)
        }
    }

    func testOnlyTheNextSlideRendersAheadAndSkippingCancelsWhatNobodyWillSee() async throws {
        SlideshowController.current?.end()   // one left by a failed test would take this one's place
        let gpu = try await GPUContext.shared()
        let fake = try FakeSlides(gpu: gpu)
        var settings = SlideshowSettings()
        settings.interval = 60
        settings.transition = .cut
        let source = SlideshowController.Source(records: records(4), start: 1, library: Library(), gpu: gpu,
                                                render: { record, _ in try await fake.make(record.fileName) })
        let show = try XCTUnwrap(SlideshowController.start(source, from: nil, settings: settings))

        try await until("the first slide to be asked for") { fake.requested == ["IMG_1.NEF"] }
        XCTAssertEqual(show.targetIndex, 1)
        XCTAssertTrue(show.keepsDisplayAwake)
        fake.finish("IMG_1.NEF")
        try await until("the first slide") { show.shownIndex == 1 }
        try await until("the next slide, and only it") { fake.requested == ["IMG_1.NEF", "IMG_2.NEF"] }

        show.controlBarCommand(.next)
        XCTAssertEqual(show.targetIndex, 2, "waits for a slide that isn't ready")
        XCTAssertEqual(show.shownIndex, 1)
        show.controlBarCommand(.next)
        XCTAssertEqual(show.targetIndex, 3, "a further step moves the target on")
        try await until("the skipped render to be cancelled") {
            fake.cancelled == ["IMG_2.NEF"] && fake.requested.last == "IMG_3.NEF"
        }

        fake.fail("IMG_3.NEF")
        try await until("the show to go on past the failed slide") {
            show.targetIndex == 0 && fake.requested.last == "IMG_0.NEF"
        }
        fake.finish("IMG_0.NEF")
        try await until("the slide after it") { show.shownIndex == 0 }
        XCTAssertTrue(show.sequence.failed.contains(3))

        show.setPaused(true)
        XCTAssertFalse(show.keepsDisplayAwake, "the display may sleep while paused")
        show.setPaused(false)
        XCTAssertTrue(show.keepsDisplayAwake)

        show.end()
        XCTAssertNil(SlideshowController.current)
        XCTAssertFalse(show.keepsDisplayAwake)
        XCTAssertNil(show.renderingIndex)
        XCTAssertFalse(show.window?.isVisible ?? false)
    }

    func testAShowThatDoesNotLoopEndsAfterTheLastSlide() async throws {
        SlideshowController.current?.end()   // one left by a failed test would take this one's place
        let gpu = try await GPUContext.shared()
        let fake = try FakeSlides(gpu: gpu)
        var settings = SlideshowSettings()
        settings.interval = 1
        settings.loop = false
        settings.transition = .cut
        let source = SlideshowController.Source(records: records(2), start: 1, library: Library(), gpu: gpu,
                                                render: { record, _ in try await fake.make(record.fileName) })
        var ended = false
        let show = try XCTUnwrap(SlideshowController.start(source, from: nil, settings: settings) { _ in ended = true })
        try await until("the last slide to be asked for") { fake.requested == ["IMG_1.NEF"] }
        fake.finish("IMG_1.NEF")
        try await until("the last slide") { show.shownIndex == 1 }
        XCTAssertNil(show.renderingIndex, "nothing comes after it")
        try await until("the show to end after its interval") { ended }
        XCTAssertTrue(show.hasEnded)
    }

    func testAShowWithNothingToShowEndsAndSaysSo() async throws {
        SlideshowController.current?.end()   // one left by a failed test would take this one's place
        let gpu = try await GPUContext.shared()
        let fake = try FakeSlides(gpu: gpu)
        let source = SlideshowController.Source(records: records(2), start: 0, library: Library(), gpu: gpu,
                                                render: { record, _ in try await fake.make(record.fileName) })
        var message: String?
        let show = try XCTUnwrap(SlideshowController.start(source, from: nil) { message = $0 })
        try await until("the first slide to be asked for") { fake.requested == ["IMG_0.NEF"] }
        fake.fail("IMG_0.NEF")
        try await until("the second") { fake.requested.last == "IMG_1.NEF" }
        fake.fail("IMG_1.NEF")
        try await until("the end") { show.hasEnded }
        XCTAssertEqual(message, "The slideshow couldn’t show any of the images")
    }
}

@MainActor
final class SlideshowMusicTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("latent-music-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A few seconds of quiet tone, as a song.
    private func song() throws -> SlideshowSettings.Song {
        let url = folder.appendingPathComponent("tone.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 5))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { samples[i] = 0.01 * sin(Float(i) * 0.06) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return SlideshowSettings.Song(name: "tone", bookmark: try url.bookmarkData())
    }

    /// Paused while the song was still opening, the show's music fades in
    /// when it resumes rather than playing silently to the end.
    func testASongOpenedWhilePausedFadesInOnResume() async throws {
        let music = SlideshowMusic(songs: [try song()])
        music.start()
        // Before the song can finish opening off the main thread.
        music.pause()
        await waitUntil("the song to open") { music.currentPlayer != nil }
        let player = try XCTUnwrap(music.currentPlayer)
        XCTAssertEqual(player.volume, 0)
        XCTAssertFalse(player.isPlaying)
        music.resume()
        try await Task.sleep(for: .seconds(SlideshowMusic.fadeInDuration + 0.5))
        XCTAssertEqual(player.volume, SlideshowMusic.volume, accuracy: 0.01)
        music.finish()
    }
}
