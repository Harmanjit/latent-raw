#if DEBUG
import XCTest
@testable import Catalog

final class SnapshotPlanTests: XCTestCase {
    func testOffWithoutADirectory() throws {
        XCTAssertNil(try SnapshotPlan(environment: [:]))
        XCTAssertNil(try SnapshotPlan(environment: ["LATENT_SNAPSHOT_DIR": ""]))
        XCTAssertNil(try SnapshotPlan(environment: ["LATENT_SNAPSHOT_FOLDER": "/tmp", "LATENT_SNAPSHOT_STEPS": "library"]))
    }

    func testDefaults() throws {
        let plan = try XCTUnwrap(try SnapshotPlan(environment: ["LATENT_SNAPSHOT_DIR": "/tmp/shots"]))
        XCTAssertEqual(plan.directory.path, "/tmp/shots")
        XCTAssertNil(plan.folder)
        XCTAssertEqual(plan.steps, SnapshotPlan.defaultSteps)
        XCTAssertEqual(plan.windowSize, SnapshotPlan.defaultWindowSize)
        XCTAssertEqual(plan.settle, 1)
        XCTAssertEqual(plan.timeout, 120)
        XCTAssertNil(plan.appearance)
        XCTAssertFalse(plan.systemFullScreen)
    }

    func testReadsEveryVariable() throws {
        let plan = try XCTUnwrap(try SnapshotPlan(environment: [
            "LATENT_SNAPSHOT_DIR": "~/shots",
            "LATENT_SNAPSHOT_FOLDER": "/Users/someone/Pictures/../Pictures/Trip",
            "LATENT_SNAPSHOT_STEPS": " Library; loupe,,develop ;next;next ",
            "LATENT_SNAPSHOT_SIZE": "1400X900",
            "LATENT_SNAPSHOT_SETTLE": "0.25",
            "LATENT_SNAPSHOT_TIMEOUT": "30",
            "LATENT_SNAPSHOT_APPEARANCE": "Dark",
            "LATENT_SNAPSHOT_FULLSCREEN": "System",
        ]))
        XCTAssertFalse(plan.directory.path.hasPrefix("~"))
        XCTAssertEqual(plan.folder?.path, "/Users/someone/Pictures/Trip")
        XCTAssertEqual(plan.steps, [.library, .loupe, .develop, .next, .next])
        XCTAssertEqual(plan.windowSize, CGSize(width: 1400, height: 900))
        XCTAssertEqual(plan.settle, 0.25)
        XCTAssertEqual(plan.timeout, 30)
        XCTAssertEqual(plan.appearance, "dark")
        XCTAssertTrue(plan.systemFullScreen)
    }

    /// A typo must fail the run, not quietly picture something else.
    func testMalformedValuesThrow() {
        let base = ["LATENT_SNAPSHOT_DIR": "/tmp/shots"]
        func problem(_ extra: [String: String]) -> SnapshotPlan.Problem? {
            do {
                _ = try SnapshotPlan(environment: base.merging(extra) { $1 })
                return nil
            } catch {
                return error as? SnapshotPlan.Problem
            }
        }
        XCTAssertEqual(problem(["LATENT_SNAPSHOT_STEPS": "library;devlop;grid"]), .unknownSteps(["devlop", "grid"]))
        XCTAssertEqual(problem(["LATENT_SNAPSHOT_SIZE": "1400"]),
                       .malformed(variable: "LATENT_SNAPSHOT_SIZE", value: "1400"))
        XCTAssertEqual(problem(["LATENT_SNAPSHOT_SETTLE": "soon"]),
                       .malformed(variable: "LATENT_SNAPSHOT_SETTLE", value: "soon"))
        XCTAssertEqual(problem(["LATENT_SNAPSHOT_TIMEOUT": "-5"]),
                       .malformed(variable: "LATENT_SNAPSHOT_TIMEOUT", value: "-5"))
        XCTAssertEqual(problem(["LATENT_SNAPSHOT_APPEARANCE": "sepia"]),
                       .malformed(variable: "LATENT_SNAPSHOT_APPEARANCE", value: "sepia"))
        XCTAssertEqual(problem(["LATENT_SNAPSHOT_FULLSCREEN": "yes"]),
                       .malformed(variable: "LATENT_SNAPSHOT_FULLSCREEN", value: "yes"))
        XCTAssertNil(problem(["LATENT_SNAPSHOT_STEPS": ""]), "an empty variable is unset, not an empty plan")
    }

    func testViewingModeSteps() throws {
        XCTAssertEqual(try SnapshotPlan.parseSteps("fullscreen; Fullscreen-Right, fullscreen-left;fullscreen-bottom;second-display"),
                       [.fullscreen, .fullscreenRight, .fullscreenLeft, .fullscreenBottom, .secondDisplay])
        XCTAssertEqual(SnapshotPlan.Step.allCases.filter(\.isFullScreen),
                       [.fullscreen, .fullscreenLeft, .fullscreenRight, .fullscreenBottom])
    }

    /// The Wave 2 steps, and which steps open a tool's group at the end
    /// of the adjustments panel.
    func testRetouchSteps() throws {
        XCTAssertEqual(try SnapshotPlan.parseSteps("dust,touchup,models"), [.dust, .touchUp, .models])
        XCTAssertEqual(SnapshotPlan.Step.allCases.filter(\.armsATool), [.crop, .heal, .redEye, .dust, .touchUp])
        XCTAssertFalse(SnapshotPlan.Step.models.armsATool)
    }

    func testSizeParsing() {
        XCTAssertEqual(SnapshotPlan.parseSize(" 1200 x 800 "), CGSize(width: 1200, height: 800))
        XCTAssertNil(SnapshotPlan.parseSize("0x900"))
        XCTAssertNil(SnapshotPlan.parseSize("wide x tall"))
        XCTAssertNil(SnapshotPlan.parseSize("1x2x3"))
    }

    /// Numbered in run order, so a repeated step gets a file of its own.
    func testOutputNamesFollowTheSteps() throws {
        let plan = try XCTUnwrap(try SnapshotPlan(environment: ["LATENT_SNAPSHOT_DIR": "/tmp/shots",
                                                                "LATENT_SNAPSHOT_STEPS": "develop;next;next"]))
        XCTAssertEqual(plan.steps.indices.map { plan.output(forStepAt: $0).lastPathComponent },
                       ["01-develop.png", "02-next.png", "03-next.png"])
        XCTAssertEqual(plan.output(forStepAt: 0).deletingLastPathComponent().path, "/tmp/shots")
    }
}
#endif
