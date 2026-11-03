import XCTest
import Metal
@testable import PixelEngine
@testable import RawCore

/// HDR Limit: an optional module of the edit, off (two stops) by default.
final class HDRLimitTests: XCTestCase {
    func testDefaultIsTheOldFixedCeilingAndIsNotWritten() throws {
        let p = EditParameters()
        XCTAssertEqual(p.hdrLimitStops, 2)
        XCTAssertEqual(p.hdrHeadroom, GainMap.exportHeadroom)
        XCTAssertEqual(p.hdrHeadroom, DisplayHeadroom.renderCeiling)
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertFalse(json.contains("\"hdr\""), "an edit that never touched it encodes as before")
    }

    func testParametersDifferByTheLimit() {
        var p = EditParameters()
        p.hdrLimitStops = 1
        XCTAssertNotEqual(p, EditParameters(), "a limit change must count as an edit")
    }

    func testLimitSurvivesSaveAndReload() throws {
        var p = EditParameters()
        p.exposureEV = 0.4
        p.hdrLimitStops = 1.5
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"hdr\""))
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.hdrHeadroom, exp2(1.5), accuracy: 1e-5)
    }

    func testOldEditsLoadWithTheDefaultAndBadValuesAreClamped() throws {
        let old = #"{"schema":1,"process":"1.0","modules":{"exposure":{"ev":0.5}}}"#
        XCTAssertEqual(try EditStack.decode(json: old).parameters().hdrLimitStops, HDRLimit.defaultStops)
        let wild = #"{"schema":1,"process":"1.0","modules":{"hdr":{"limit":40}}}"#
        XCTAssertEqual(try EditStack.decode(json: wild).parameters().hdrLimitStops, HDRLimit.range.upperBound)
        XCTAssertEqual(HDRLimit.clamped(.nan), HDRLimit.defaultStops)
        XCTAssertEqual(HDRLimit.clamped(0), HDRLimit.range.lowerBound)
    }

    func testDisplayCeilingFollowsTheLimit() {
        XCTAssertEqual(DisplayHeadroom.rendered(potential: 16, hdrDisplayEnabled: true, limit: exp2(1)), 2)
        XCTAssertEqual(DisplayHeadroom.rendered(potential: 16, hdrDisplayEnabled: true, limit: exp2(3)), 8)
        XCTAssertEqual(DisplayHeadroom.rendered(potential: 3, hdrDisplayEnabled: true, limit: exp2(3)), 3,
                       "never past what the screen can do")
        XCTAssertEqual(DisplayHeadroom.rendered(potential: 16, hdrDisplayEnabled: false, limit: 8), 1)
        // The default limit is the ceiling Latent always used.
        XCTAssertEqual(DisplayHeadroom.rendered(potential: 16, hdrDisplayEnabled: true,
                                                limit: EditParameters().hdrHeadroom), 4)
    }

    func testCopiedWithToneAndNamedInHistory() throws {
        var source = EditParameters()
        source.hdrLimitStops = 1
        let from = EditStack(parameters: source)
        let to = EditStack(parameters: EditParameters())
        XCTAssertTrue(from.presentGroups.contains(.tone))
        XCTAssertEqual(to.merged(with: from, groups: [.tone]).parameters().hdrLimitStops, 1)
        XCTAssertEqual(to.merged(with: from, groups: [.colour]).parameters().hdrLimitStops, 2)
        XCTAssertEqual(EditHistory.describeChange(from: to, to: from), "HDR Limit")
    }

    /// A gain-map export carries the photo's limit as its headroom.
    func testGainMapRangeFollowsTheLimit() {
        let narrow = GainMap.log2Range(headroom: HDRLimit.headroom(stops: 1))
        let wide = GainMap.log2Range(headroom: HDRLimit.headroom(stops: 3))
        XCTAssertEqual(narrow.maximum, 1, accuracy: 1e-5)
        XCTAssertEqual(wide.maximum, 3, accuracy: 1e-5)
    }

    /// The export itself: a gain map made for a photo limited to one stop
    /// carries one stop of headroom, and its HDR rendition is rendered to it.
    func testGainMapExportUsesThePhotosLimit() throws {
        let path = TestAssets.path("golden_nikon_d750_cc0.nef")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let gpu = try GPUContext()
        let file = try RawFile(path: path)
        let session = try ImageSession(file: file, gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var parameters = EditParameters()
        parameters.whiteBalance = session.asShotWhiteBalance
        parameters.hdrLimitStops = 1
        let scale = ExportPlan.scale(for: file.summary, maxLongEdge: 320)
        var asked: [Float] = []
        func render(_ output: RenderOutput) throws -> MTLTexture {
            asked.append(output.headroom)
            return try pipeline.render(session, scale: scale, parameters: parameters, output: output)
        }
        let prepared = try Exporter(gpu: gpu).encodableImage(
            try render(.file(.displayP3)), settings: ExportSettings(format: .jpeg, hdrGainMap: true),
            colorSpace: .displayP3, maxLongEdge: 320, hdrHeadroom: parameters.hdrHeadroom, hdrRender: render)
        XCTAssertEqual(try XCTUnwrap(prepared.gainMap).headroom, 2, accuracy: 1e-5)
        XCTAssertEqual(asked.last ?? 0, 2, accuracy: 1e-5, "the HDR rendition is rendered to the limit")
    }
}
