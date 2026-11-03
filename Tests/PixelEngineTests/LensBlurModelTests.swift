import XCTest
import simd
@testable import PixelEngine
@testable import RawCore

/// Lens Blur's edit module (LensBlur.swift): how it is stored, read back,
/// copied and named, and the arithmetic the kernel shares with Swift.
final class LensBlurModelTests: XCTestCase {
    static let blur = LensBlur(amount: 60, bokeh: .blades5, boost: 35, focusFar: 0.42, focusNear: 0.81,
                               depthModel: "depth-anything-v2-small@1")

    // MARK: - Storage

    /// An edit that never used Lens Blur encodes exactly as before: no key.
    func testNeutralBlurIsNotStored() throws {
        let json = try EditStack(parameters: EditParameters()).encodeJSON()
        XCTAssertFalse(json.contains("lensblur"))
        XCTAssertNil(EditStack(parameters: EditParameters()).modules.lensblur)
    }

    /// Saved and loaded again, an edit with a blur comes back whole.
    func testRoundTripThroughJSON() throws {
        var p = EditParameters()
        p.exposureEV = 0.3
        p.lensBlur = Self.blur
        let json = try EditStack(parameters: p).encodeJSON()
        XCTAssertTrue(json.contains("\"lensblur\""))
        XCTAssertTrue(json.contains("\"schema\":1"), "the schema number is unchanged")
        let back = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(back.lensBlur, Self.blur)
        XCTAssertEqual(back, p)
        // And again: the second save is byte-identical to the first.
        XCTAssertEqual(try EditStack(parameters: back).encodeJSON(), json)
    }

    /// A focus range moved with the amount at 0 is kept, so turning the
    /// amount up again finds it; the stage stays off meanwhile.
    func testFocusRangeWithoutAmountIsKeptButInactive() throws {
        var p = EditParameters()
        p.lensBlur.focusFar = 0.2
        let back = try EditStack.decode(json: EditStack(parameters: p).encodeJSON()).parameters()
        XCTAssertEqual(back.lensBlur.focusFar, 0.2)
        XCTAssertFalse(back.lensBlur.isActive)
    }

    /// An edit written before Lens Blur existed loads with it off.
    func testOldEditLoadsWithBlurOff() throws {
        let json = #"{"schema":1,"process":"1.0","modules":{"exposure":{"ev":-0.5}}}"#
        let p = try EditStack.decode(json: json).parameters()
        XCTAssertEqual(p.lensBlur, .neutral)
        XCTAssertFalse(p.lensBlur.isActive)
    }

    /// Missing keys keep their defaults, an unknown bokeh reads as a
    /// circle, and values out of range are brought into it.
    func testLenientDecodingAndSanitising() throws {
        let json = #"{"schema":1,"process":"1.0","modules":{"lensblur":{"amount":1e9,"bokeh":"hexagon","focusFar":0.9,"focusNear":0.1,"future":true}}}"#
        let blur = try EditStack.decode(json: json).parameters().lensBlur
        XCTAssertEqual(blur.amount, 100)
        XCTAssertEqual(blur.bokeh, .circle)
        XCTAssertEqual(blur.boost, 0)
        XCTAssertEqual(blur.focusFar, 0.1, "crossed edges are put in order")
        XCTAssertEqual(blur.focusNear, 0.9)
        XCTAssertNil(blur.depthModel)
        let nan = LensBlur(amount: .nan, boost: .infinity, focusFar: -3, focusNear: .nan).sanitized
        XCTAssertEqual(nan.amount, 0)
        XCTAssertEqual(nan.boost, 0)
        XCTAssertEqual(nan.focusFar, 0)
        XCTAssertEqual(nan.focusNear, 1)
    }

    // MARK: - Copy, presets, history

    func testLensBlurGroupCopiesTheModuleOnly() throws {
        var a = EditParameters(); a.exposureEV = 1
        var b = EditParameters(); b.exposureEV = -1; b.lensBlur = Self.blur
        let merged = EditStack(parameters: a).merged(with: EditStack(parameters: b), groups: [.lensBlur]).parameters()
        XCTAssertEqual(merged.lensBlur, Self.blur)
        XCTAssertEqual(merged.exposureEV, 1)
        XCTAssertEqual(EditStack(parameters: b).presentGroups.contains(.lensBlur), true)
        XCTAssertFalse(EditGroup.lookGroups.contains(.lensBlur), "the look doesn't carry a focus range by default")
        // Pasting "no lens blur" clears it.
        let cleared = EditStack(parameters: b).merged(with: EditStack(parameters: a), groups: [.lensBlur])
        XCTAssertNil(cleared.modules.lensblur)
        XCTAssertEqual(EditStack(parameters: b).restricted(to: [.lensBlur]).modules.lensblur, Self.blur)
    }

    func testHistoryNamesTheChange() {
        var b = EditParameters(); b.lensBlur = Self.blur
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(parameters: EditParameters()),
                                                  to: EditStack(parameters: b)), "Lens Blur")
    }

    // MARK: - Arithmetic

    func testBlurFractionGrowsOutsideTheFocusRange() {
        let blur = LensBlur(amount: 100, focusFar: 0.4, focusNear: 0.6)
        XCTAssertEqual(blur.blurFraction(atDepth: 0.5), 0)
        XCTAssertEqual(blur.blurFraction(atDepth: 0.4), 0)
        XCTAssertEqual(blur.blurFraction(atDepth: 0.6), 0)
        XCTAssertEqual(blur.blurFraction(atDepth: 0.4 - LensBlur.fullBlurDepth / 2), 0.5, accuracy: 1e-5)
        XCTAssertEqual(blur.blurFraction(atDepth: 0), 1)
        XCTAssertEqual(blur.blurFraction(atDepth: 0.95), 1, accuracy: 1e-5, "nearer than the range blurs too")
        XCTAssertEqual(blur.maximumRadius(longEdge: 6000), 120, accuracy: 1e-3)
        XCTAssertEqual(LensBlur(amount: 50).maximumRadius(longEdge: 6000), 60, accuracy: 1e-3)
    }

    func testTileReachCoversTheLargestBlur() {
        var p = EditParameters()
        XCTAssertEqual(p.lensBlurTileReach(sensorSize: CGSize(width: 6000, height: 4000)), 0)
        p.lensBlur.amount = 100
        let reach = p.lensBlurTileReach(sensorSize: CGSize(width: 6000, height: 4000))
        XCTAssertGreaterThanOrEqual(reach, 120)
        XCTAssertLessThan(reach, 160)
    }

    func testFocusRangeAroundAPointStaysInside() {
        let mid = LensBlur.focusRange(around: 0.5)
        XCTAssertEqual(mid.far, 0.42, accuracy: 1e-5)
        XCTAssertEqual(mid.near, 0.58, accuracy: 1e-5)
        let top = LensBlur.focusRange(around: 0.99)
        XCTAssertEqual(top.near, 1)
        XCTAssertEqual(top.far, 0.84, accuracy: 1e-5)
        let bottom = LensBlur.focusRange(around: -1)
        XCTAssertEqual(bottom.far, 0)
        XCTAssertEqual(bottom.near, 0.16, accuracy: 1e-5)
    }

    func testReductionKeepsTheGatherSmall() {
        XCTAssertEqual(LensBlurStage.reduction(forRadius: 0), 1)
        XCTAssertEqual(LensBlurStage.reduction(forRadius: LensBlurStage.gatherRadius), 1)
        XCTAssertEqual(LensBlurStage.reduction(forRadius: 120), Int((120 / LensBlurStage.gatherRadius).rounded(.up)))
        XCTAssertEqual(LensBlurStage.reduction(forRadius: .infinity), 1)
        XCTAssertLessThanOrEqual(LensBlurStage.taps.count * MemoryLayout<SIMD2<Float>>.stride, 4096,
                                 "the taps go by setBytes")
        XCTAssertTrue(LensBlurStage.taps.allSatisfy { simd_length($0) <= 1.0001 })
        XCTAssertEqual(LensBlurStage.taps.first, .zero, "the centre tap is what keeps every pixel covered")
    }

    // MARK: - Depth maps

    func testDepthMapSamplingHistogramAndTwoPlanes() {
        let map = DepthMap(bitmap: MaskBitmap(width: 2, height: 1, data: [0, 255]), source: "x@1")
        XCTAssertEqual(map.depth(atNormalized: SIMD2(0, 0.5)), 0, accuracy: 1e-5)
        XCTAssertEqual(map.depth(atNormalized: SIMD2(1, 0.5)), 1, accuracy: 1e-5)
        XCTAssertEqual(map.depth(atNormalized: SIMD2(0.5, 0.5)), 0.5, accuracy: 1e-3)
        let histogram = map.histogram(bins: 4)
        XCTAssertEqual(histogram, [0.5, 0, 0, 0.5])

        let mask = MaskBitmap(width: 3, height: 1, data: [0, 128, 255])
        let planes = DepthMap.twoPlane(fromSubject: mask)
        XCTAssertEqual(planes.source, LensBlur.subjectDepthVersion)
        XCTAssertEqual(planes.bitmap.data.first, DepthMap.twoPlaneFar)
        XCTAssertEqual(planes.bitmap.data.last, DepthMap.twoPlaneNear)
        // The default focus range keeps the subject sharp and blurs the
        // background fully.
        let blur = LensBlur(amount: 100)
        XCTAssertEqual(blur.blurFraction(atDepth: Float(DepthMap.twoPlaneNear) / 255), 0)
        XCTAssertEqual(blur.blurFraction(atDepth: Float(DepthMap.twoPlaneFar) / 255), 1)
    }

    func testSessionHoldsTheDepthMap() throws {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.plain)), gpu: gpu)
        XCTAssertFalse(session.hasDepthMap)
        XCTAssertNil(session.depthTexture())
        let map = DepthMap(bitmap: MaskBitmap(width: 4, height: 2, data: [UInt8](repeating: 9, count: 8)), source: "s")
        session.setDepthMap(map)
        XCTAssertEqual(session.depthMap, map)
        let texture = try XCTUnwrap(session.depthTexture())
        XCTAssertEqual(texture.width, 4)
        XCTAssertTrue(texture === session.depthTexture(), "uploaded once")
        session.releaseMemory(for: .critical)
        XCTAssertTrue(session.hasDepthMap, "small enough to keep through memory pressure")
        session.setDepthMap(nil)
        XCTAssertNil(session.depthTexture())
    }
}
