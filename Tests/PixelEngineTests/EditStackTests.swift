import XCTest
import ColorKit
@testable import PixelEngine

final class EditStackTests: XCTestCase {
    func testRoundTripPreservesParameters() throws {
        var p = EditParameters()
        p.whiteBalance = ColorKit.WhiteBalance(temperature: 4300, tint: -7)
        p.exposureEV = 0.7
        p.contrast = 1.8
        p.greyPoint = 0.2
        p.highlightRecovery = 0.5
        p.highlightThreshold = 0.9
        p.demosaic = .bilinear

        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"schema\":1"))
        XCTAssertTrue(json.contains("\"whitebalance\""))
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back, p)
    }

    func testAsShotWhiteBalanceStaysAsShot() throws {
        let json = try EditStack(parameters: EditParameters()).encodeJSON()
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertTrue(back.whiteBalance.isAsShot)
    }

    /// A sidecar from a future build with a module this one doesn't know
    /// still loads, and a missing module leaves the default alone.
    func testUnknownAndMissingModulesAreTolerated() throws {
        let json = """
        {"schema":1,"process":"1.0","modules":{
            "exposure":{"ev":-1.0},
            "lens":{"enabled":true,"profile":"Sony FE 24-70"},
            "tone":{"method":"sigmoid","contrast":2.0,"grey":0.18}
        }}
        """
        var defaults = EditParameters()
        defaults.highlightRecovery = 0.25
        let p = try EditStack.decode(json: json).parameters(defaults: defaults)
        XCTAssertEqual(p.exposureEV, -1.0)
        XCTAssertEqual(p.contrast, 2.0)
        XCTAssertEqual(p.highlightRecovery, 0.25, "untouched module keeps the default")
    }

    /// A stack from a newer build must not be read leniently: the save that
    /// follows would re-encode it as this build's schema and erase whatever
    /// this build doesn't know.
    func testNewerSchemaIsRefusedNotDroppedSilently() {
        let json = #"{"schema":2,"process":"1.0","modules":{"exposure":{"ev":0.5},"futureModule":{"x":1}}}"#
        XCTAssertThrowsError(try EditStack.decode(json: json)) { error in
            XCTAssertEqual(error as? EditStack.DecodeError, .newerSchema(2))
            XCTAssertTrue(error.localizedDescription.contains("newer version of Latent"))
        }
        // This build's own schema still reads.
        XCTAssertNoThrow(try EditStack.decode(json: #"{"schema":1,"process":"1.0","modules":{"exposure":{"ev":0.5}}}"#))
    }

    func testIsDefault() {
        let defaults = EditParameters()
        XCTAssertTrue(EditStack.isDefault(defaults, relativeTo: defaults))
        var edited = defaults
        edited.exposureEV = 0.1
        XCTAssertFalse(EditStack.isDefault(edited, relativeTo: defaults))
        // Output space isn't part of the edit, so changing it isn't an edit.
        var exportOnly = defaults
        exportOnly.outputSpace = .displayP3
        XCTAssertTrue(EditStack.isDefault(exportOnly, relativeTo: defaults))
    }
}
