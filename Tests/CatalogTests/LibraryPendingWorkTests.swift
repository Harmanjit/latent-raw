import XCTest
@testable import Catalog

/// `perform` bookkeeping, which quitting relies on. Needs no catalog: the
/// operations here are plain closures.
@MainActor
final class LibraryPendingWorkTests: XCTestCase {
    private struct Refused: Error {}

    /// Collects what finished, from the operations' main-actor closures.
    @MainActor private final class Finished {
        var names: [String] = []
    }

    func testWaitReturnsAtOnceWhenIdle() async {
        let library = Library()
        XCTAssertFalse(library.hasPendingWork)
        await library.waitForPendingWork()
        XCTAssertFalse(library.hasPendingWork)
    }

    func testWaitCoversSlowFailingAndChainedOperations() async {
        let library = Library()
        let finished = Finished()
        library.perform("Slow") {
            try await Task.sleep(for: .milliseconds(200))
            finished.names.append("slow")
        }
        library.perform("Failing") {
            try await Task.sleep(for: .milliseconds(50))
            finished.names.append("failing")
            throw Refused()
        }
        // Starts its follow-up after the others are done, and the follow-up
        // outlasts them all: the wait must cover it too.
        library.perform("Chained") {
            try await Task.sleep(for: .milliseconds(250))
            library.perform("Follow-up") {
                try await Task.sleep(for: .milliseconds(200))
                finished.names.append("follow-up")
            }
        }
        XCTAssertTrue(library.hasPendingWork)

        await library.waitForPendingWork()

        XCTAssertEqual(Set(finished.names), ["slow", "failing", "follow-up"])
        XCTAssertFalse(library.hasPendingWork)
        XCTAssertNotNil(library.lastError, "a failure still counts as finished, and is reported")
    }

    func testEveryWaiterIsResumed() async {
        let library = Library()
        let finished = Finished()
        library.perform("Write") {
            try await Task.sleep(for: .milliseconds(100))
            finished.names.append("write")
        }
        // Tasks rather than `async let`: on CI's Swift 6.1 an async-let child
        // waiting on the main actor aborted the test process.
        let first = Task { await library.waitForPendingWork() }
        let second = Task { await library.waitForPendingWork() }
        await first.value
        await second.value
        XCTAssertEqual(finished.names, ["write"])
        XCTAssertFalse(library.hasPendingWork)
    }
}
