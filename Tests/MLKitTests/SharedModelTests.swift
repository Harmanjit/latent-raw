import XCTest
import os
@testable import MLKit

/// Stands in for a Core ML model: something big enough to be worth
/// releasing, counted so the test sees every load.
private final class FakeModel: Sendable {
    let generation: Int
    init(generation: Int) { self.generation = generation }
}

final class SharedModelTests: XCTestCase {
    func testLoadsOnceUntilReleasedThenLoadsAgain() async {
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let shared = SharedModel<FakeModel> {
            FakeModel(generation: loads.withLock { $0 += 1; return $0 })
        }
        XCTAssertFalse(shared.isLoaded, "nothing loads before someone asks")

        let first = await shared.value
        let again = await shared.value
        XCTAssertEqual(first?.generation, 1)
        XCTAssertTrue(first === again, "every caller shares one load")
        XCTAssertTrue(shared.isLoaded)

        shared.release()
        XCTAssertFalse(shared.isLoaded)
        let reloaded = await shared.value
        XCTAssertEqual(reloaded?.generation, 2)
        XCTAssertEqual(loads.withLock { $0 }, 2)
    }

    /// Releasing must actually free the model once no caller holds it,
    /// or memory pressure gets nothing back.
    func testReleaseLetsTheModelGo() async {
        let shared = SharedModel<FakeModel> { FakeModel(generation: 1) }
        weak var loaded: FakeModel?
        loaded = await shared.value
        XCTAssertNotNil(loaded, "the shared reference keeps it alive")
        shared.release()
        XCTAssertNil(loaded)
    }

    /// A model that isn't bundled answers nil, and that answer is kept
    /// rather than retried on every click.
    func testMissingModelIsNilAndNotRetried() async {
        let loads = OSAllocatedUnfairLock(initialState: 0)
        let shared = SharedModel<FakeModel> {
            loads.withLock { $0 += 1 }
            return nil
        }
        let a = await shared.value
        let b = await shared.value
        XCTAssertNil(a)
        XCTAssertNil(b)
        XCTAssertEqual(loads.withLock { $0 }, 1)
    }
}
