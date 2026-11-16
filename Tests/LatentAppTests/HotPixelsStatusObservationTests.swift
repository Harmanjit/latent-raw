import XCTest
import Observation
import PixelEngine
@testable import latent_app

/// Detail › Hot Pixels shows a count the render stores in the session,
/// where observation can't see it. The section must still update when
/// that render lands, not stay on "Counting…".
@MainActor
final class HotPixelsStatusObservationTests: XCTestCase {
    func testTheCountIsReadAgainWhenARenderLands() {
        let model = EditorModel()
        for land in [{ model.preview = nil }, { model.tile = nil }] {
            let changed = ChangeFlag()
            withObservationTracking {
                _ = model.hotPixelsFixedAfterRender(for: HotPixelRemoval())
            } onChange: {
                changed.set()
            }
            land()
            XCTAssertTrue(changed.isSet)
        }
    }
}

/// Set from observation's change callback, which is `@Sendable`.
private final class ChangeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
