import XCTest
import Catalog
@testable import latent_app

/// Settings › Performance and File › Rebuild Thumbnails.
@MainActor
final class PerformanceSettingsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "latent.performance.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultsAreWhatLatentAlwaysDid() {
        let settings = PerformanceSettings(defaults: defaults)
        XCTAssertEqual(settings.thumbnailQuality, .standard)
        XCTAssertEqual(settings.thumbnailPriority, .normal)
        XCTAssertEqual(settings.memoryCache, .automatic)
        XCTAssertEqual(settings.memoryCache.bytes, ThumbnailLoader.defaultMemoryBytes)
        XCTAssertEqual(settings.generation, ThumbnailGenerationSettings())
    }

    func testChoicesAreRememberedAndReachTheLibrary() {
        let library = Library()
        let settings = PerformanceSettings(defaults: defaults)
        settings.apply(to: library)
        settings.thumbnailQuality = .high
        settings.thumbnailPriority = .low
        settings.memoryCache = .small
        XCTAssertEqual(library.thumbnailGeneration, ThumbnailGenerationSettings(quality: .high, priority: .low))
        XCTAssertEqual(library.thumbnailLoader.memoryBudget, 128 << 20)

        let reopened = PerformanceSettings(defaults: defaults)
        XCTAssertEqual(reopened.thumbnailQuality, .high)
        XCTAssertEqual(reopened.thumbnailPriority, .low)
        XCTAssertEqual(reopened.memoryCache, .small)
    }

    func testRebuildThumbnailsNeedsAFolderAndASelection() {
        var state = CommandState()
        XCTAssertFalse(state.isEnabled(.rebuildThumbnails))
        state.hasFolder = true
        XCTAssertFalse(state.isEnabled(.rebuildThumbnails), "nothing selected")
        state.selectionCount = 3
        XCTAssertTrue(state.isEnabled(.rebuildThumbnails))
        state.selectionCount = 0
        state.hasSelection = true
        state.mode = .develop
        XCTAssertTrue(state.isEnabled(.rebuildThumbnails), "the photo on screen")
        state.mode = .survey
        XCTAssertFalse(state.isEnabled(.rebuildThumbnails))
        XCTAssertNil(Shortcuts.shortcut(for: .rebuildThumbnails), "menu only")
    }
}
