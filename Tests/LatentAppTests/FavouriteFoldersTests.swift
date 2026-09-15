import XCTest
@testable import latent_app
@testable import Catalog

/// Bringing back a favourite whose disk was away, in the order the App
/// Sandbox needs, with the sandbox played by the stand-in steps.
final class FavouriteFoldersTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/Volumes/Photos/2026", isDirectory: true)

    /// Records the steps; the folder opens only once its scope has started,
    /// as under the sandbox.
    private final class Sandbox: @unchecked Sendable {
        var steps: [String] = []
        var scopeStarted = false
        var opens = true
    }

    private func reachable(_ sandbox: Sandbox, alreadyAccessing: Set<String> = [])
        -> (url: URL, stale: Bool, startedAccess: Bool)? {
        FavouriteFolders.reachable(
            Data(), alreadyAccessing: alreadyAccessing,
            resolve: { _ in sandbox.steps.append("resolve"); return (self.folder, false) },
            startAccess: { _ in sandbox.steps.append("start"); sandbox.scopeStarted = true; return true },
            stopAccess: { _ in sandbox.steps.append("stop"); sandbox.scopeStarted = false },
            problem: { _ in
                sandbox.steps.append("probe")
                return sandbox.scopeStarted && sandbox.opens ? nil : .notPermitted
            })
    }

    func testScopeStartsBeforeTheFolderIsProbed() {
        let sandbox = Sandbox()
        let found = reachable(sandbox)
        XCTAssertEqual(found?.url, folder)
        XCTAssertEqual(found?.startedAccess, true)
        XCTAssertEqual(sandbox.steps, ["resolve", "start", "probe"])
    }

    func testScopeStopsAgainWhenTheFolderStillWontOpen() {
        let sandbox = Sandbox()
        sandbox.opens = false
        XCTAssertNil(reachable(sandbox))
        XCTAssertEqual(sandbox.steps, ["resolve", "start", "probe", "stop"])
    }

    func testAScopeAlreadyOpenIsNeitherStartedNorStopped() {
        let sandbox = Sandbox()
        sandbox.scopeStarted = true
        sandbox.opens = false
        XCTAssertNil(reachable(sandbox, alreadyAccessing: [folder.path]))
        XCTAssertEqual(sandbox.steps, ["resolve", "probe"], "someone else's access is left open")
    }
}
