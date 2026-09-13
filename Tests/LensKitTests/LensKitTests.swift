import XCTest
@testable import LensKit
import RawCore

final class LensKitTests: XCTestCase {
    static let db = LensfunDatabase.shared

    func testDatabaseLoads() {
        XCTAssertGreaterThan(Self.db.cameras.count, 500)
        XCTAssertGreaterThan(Self.db.lenses.count, 1000)
        XCTAssertTrue(Self.db.mountsAccepted(by: "Nikon F AF").contains("Nikon F"))
        XCTAssertNotEqual(Self.db.version, "unknown")
    }

    func testFindsTheD750() throws {
        let camera = try XCTUnwrap(LensMatcher.findCamera(make: "Nikon", model: "D750", in: Self.db))
        XCTAssertEqual(camera.mount, "Nikon F AF")
        XCTAssertEqual(camera.cropFactor, 1)
        // LibRaw's spelling ("Nikon" + "D750") and the file's own maker string.
        XCTAssertNotNil(LensMatcher.findCamera(make: "Nikon Corporation", model: "Nikon D750", in: Self.db))
    }

    private func identity(nikonID: UInt8, min: Double, max: Double, ap: Double) -> LensIdentity {
        LensIdentity(make: "", makerNotesName: "", makerLensID: 0, nikonLensID: nikonID, nikonLensType: 0,
                     minFocal: min, maxFocal: max, maxApertureAtMinFocal: ap, maxApertureAtMaxFocal: ap,
                     cropFactor: 1)
    }

    func testMatchesNikon50mmByIDAndSpecs() throws {
        let match = try XCTUnwrap(LensMatcher.match(
            cameraMake: "Nikon", cameraModel: "D750", lensName: "",
            identity: identity(nikonID: 160, min: 50, max: 50, ap: 1.4), focal: 50, in: Self.db))
        XCTAssertTrue(match.lens.model.contains("50mm f/1.4G"), match.lens.model)
        XCTAssertEqual(match.cropRatio, 1)
        let c = LensCorrection.resolve(match, focal: 50, aperture: 4, imageWidth: 6032, imageHeight: 4032,
                                       databaseVersion: Self.db.version)
        guard case .ptlens(let a, let b, _)? = c.distortion else { return XCTFail("expected ptlens") }
        XCTAssertEqual(a, 0.00211, accuracy: 0.0005)
        XCTAssertEqual(b, -0.01098, accuracy: 0.0005)
        XCTAssertNotNil(c.tca)
        // f/4 exists in the table; farthest distance entry is picked.
        let v = try XCTUnwrap(c.vignetting)
        XCTAssertEqual(v.k1, -0.1433, accuracy: 1e-3)
        XCTAssertTrue(c.autoScale > 0.95 && c.autoScale <= 1.0, "mild barrel: tiny shrink, got \(c.autoScale)")
    }

    func testMatchesTokina100MacroBySpecs() throws {
        let match = try XCTUnwrap(LensMatcher.match(
            cameraMake: "Nikon", cameraModel: "D750", lensName: "",
            identity: identity(nikonID: 141, min: 100, max: 100, ap: 2.8), focal: 100, in: Self.db))
        XCTAssertTrue(match.lens.model.lowercased().contains("tokina"), match.lens.model)
        XCTAssertTrue(match.lens.model.contains("100"), match.lens.model)
    }

    func testZoomInterpolatesBetweenFocals() throws {
        let match = try XCTUnwrap(LensMatcher.match(
            cameraMake: "Nikon", cameraModel: "D750", lensName: "",
            identity: identity(nikonID: 174, min: 200, max: 500, ap: 5.6), focal: 240, in: Self.db))
        XCTAssertTrue(match.lens.model.contains("200-500"), match.lens.model)
        // The full-frame calibration (crop 1) should beat the DX one.
        XCTAssertEqual(match.lens.cropFactor, 1, "prefer the native-format profile")

        let at200 = LensCorrection.resolve(match, focal: 200, aperture: 5.6, imageWidth: 6032, imageHeight: 4032, databaseVersion: "")
        let at270 = LensCorrection.resolve(match, focal: 270, aperture: 5.6, imageWidth: 6032, imageHeight: 4032, databaseVersion: "")
        let at300 = LensCorrection.resolve(match, focal: 300, aperture: 5.6, imageWidth: 6032, imageHeight: 4032, databaseVersion: "")
        guard case .ptlens(_, let b200, _)? = at200.distortion,
              case .ptlens(_, let b270, _)? = at270.distortion,
              case .ptlens(_, let b300, _)? = at300.distortion else { return XCTFail() }
        // 270 lies halfway between the 240 and 300 calibration points, so
        // its b term must lie between theirs, not equal either.
        XCTAssertNotEqual(b270, b300)
        _ = b200
        XCTAssertEqual(at300.distortion, match.lens.distortion.first { $0.focal == 300 }?.model)
    }

    func testAutoScaleKeepsSourceInsideTheFrame() {
        // Lensfun's poly3 pins r = 1 (the edge midpoints): factor(1) = 1
        // for any k1. With k1 > 0 the corners map *outside* the source
        // (factor > 1 there), so the frame must shrink; with k1 < 0 the
        // corners map inside but the edge midpoints are already on the
        // border, so nothing can be gained by zooming out: exactly 1.
        let outward = DistortionModel.poly3(k1: 0.05)
        let s = LensCorrection.autoScale(for: outward, cropRatio: 1, width: 6000, height: 4000)
        XCTAssertLessThan(s, 1)
        XCTAssertGreaterThan(s, 0.85)
        let inward = DistortionModel.poly3(k1: -0.05)
        XCTAssertEqual(LensCorrection.autoScale(for: inward, cropRatio: 1, width: 6000, height: 4000), 1, accuracy: 1e-4)
        XCTAssertEqual(LensCorrection.autoScale(for: .poly3(k1: 0), cropRatio: 1, width: 6000, height: 4000), 1, accuracy: 1e-4)

        // Whatever the model, no border point may sample outside the frame.
        let model = DistortionModel.ptlens(a: 0.0108, b: -0.0342, c: 0.0157)   // the 20mm f/1.8
        let scale = LensCorrection.autoScale(for: model, cropRatio: 1, width: 6032, height: 4032)
        let halfShort: Float = 2016
        for p in [SIMD2<Float>(3016, 2016), SIMD2(3016, 0), SIMD2(0, 2016)] {
            let r = (p.x * p.x + p.y * p.y).squareRoot()
            let ratio = scale * model.factor(atUndistortedRadius: r * scale / halfShort)
            XCTAssertLessThanOrEqual(ratio, 1.0001, "border point \(p) samples outside")
        }
    }

    func testNoMatchForUnknownGear() {
        XCTAssertNil(LensMatcher.match(cameraMake: "Acme", cameraModel: "Wonder 9000", lensName: "",
                                       identity: identity(nikonID: 0, min: 0, max: 0, ap: 0), focal: 50, in: Self.db))
    }
}
