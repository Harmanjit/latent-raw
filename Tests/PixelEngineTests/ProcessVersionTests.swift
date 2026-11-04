import XCTest
import ColorKit
@testable import PixelEngine

/// Process versions: ordering, what an edit records, and that recording
/// them changed nothing about an existing edit's encoding.
final class ProcessVersionTests: XCTestCase {
    func testOrderingIsNumeric() {
        XCTAssertTrue(ProcessVersion.isOlder("1.0", than: "2.0"))
        XCTAssertTrue(ProcessVersion.isOlder("2.0", than: "10.0"))
        XCTAssertTrue(ProcessVersion.isOlder("1.0", than: "1.1"))
        XCTAssertFalse(ProcessVersion.isOlder("1.0", than: "1.0"))
        XCTAssertTrue(ProcessVersion.isOlder("garbage", than: "1.0"))
    }

    func testCurrentIsVersionOneAndNotOutdated() {
        XCTAssertEqual(ProcessVersion.current, .version1)
        XCTAssertEqual(EditStack.processVersion, "1.0")
        XCTAssertFalse(ProcessVersion.isOutdated("1.0"))
        XCTAssertEqual(ProcessVersion.title(for: "1.0"), "Version 1 (Current)")
        XCTAssertEqual(ProcessVersion.title(for: "7.0"), "7.0 (from a newer Latent)")
    }

    func testOutdatedAgainstAFutureVersion() {
        let v2 = ProcessVersion(id: "2.0", number: 2, changes: ["Vibrance spares skin"])
        XCTAssertTrue(ProcessVersion.isOutdated("1.0", current: v2))
        XCTAssertEqual(ProcessVersion.changes(from: "1.0", to: v2, among: [.version1, v2]), ["Vibrance spares skin"])
        XCTAssertEqual(ProcessVersion.changes(from: "2.0", to: v2, among: [.version1, v2]), [])
    }

    func testEditKeepsItsVersionThroughParameters() throws {
        var stack = EditStack(parameters: EditParameters())
        stack.process = "0.5"
        let p = stack.parameters()
        XCTAssertEqual(p.processVersion, "0.5")
        XCTAssertEqual(EditStack(parameters: p).process, "0.5")
        XCTAssertEqual(EditParameters().processVersion, ProcessVersion.current.id)
    }

    func testStoredEditEncodesByteForByte() throws {
        var p = EditParameters()
        p.exposureEV = 0.4
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains(#""process":"1.0""#))
        let again = try EditStack(parameters: EditStack.decode(json: json).parameters()).encodeJSON()
        XCTAssertEqual(again, json)
    }

    func testUpdatingAStoredEdit() throws {
        var stack = EditStack(parameters: EditParameters())
        stack.process = "0.5"
        let json = try stack.encodeJSON()
        let updated = try XCTUnwrap(EditStack.updatingProcess(json: json))
        XCTAssertEqual(try EditStack.decode(json: updated).process, ProcessVersion.current.id)
        XCTAssertNil(try EditStack.updatingProcess(json: updated))
        XCTAssertEqual(EditStack.processVersion(ofJSON: json), "0.5")
        XCTAssertEqual(EditStack.processVersion(ofJSON: nil), EditStack.processVersion)
    }

    func testHistoryNamesAProcessChange() {
        let a = EditStack(parameters: EditParameters())
        XCTAssertEqual(EditHistory.describeChange(from: a, to: a.updatingProcess(to: ProcessVersion(id: "2.0", number: 2, changes: []))),
                       "Process Version")
    }
}
