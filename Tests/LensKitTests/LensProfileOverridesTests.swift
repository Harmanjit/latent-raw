import XCTest
@testable import LensKit
import RawCore

/// Hand-picked lens profiles: the key that names a camera and lens, the
/// process-wide table, and that a choice wins over the automatic match.
final class LensProfileOverridesTests: XCTestCase {
    static let db = LensfunDatabase.shared

    private func identity(_ lo: Double, _ hi: Double, _ aperture: Double, nikonID: UInt8 = 0) -> LensIdentity {
        LensIdentity(make: "", makerNotesName: "", makerLensID: 0, nikonLensID: nikonID, nikonLensType: 0,
                     minFocal: lo, maxFocal: hi, maxApertureAtMinFocal: aperture,
                     maxApertureAtMaxFocal: aperture, cropFactor: 0)
    }

    override func tearDown() {
        LensProfileOverrides.replaceAll([:])
    }

    func testKeyNamesTheCameraAndLens() {
        let a = LensProfileOverrides.Key(cameraMake: "Nikon", cameraModel: "D750", lensName: "",
                                         identity: identity(35, 35, 1.8, nikonID: 7))
        XCTAssertEqual(a.camera, "Nikon D750")
        XCTAssertTrue(a.lens.contains("35-35mm"))
        let b = LensProfileOverrides.Key(cameraMake: "Nikon", cameraModel: "D750", lensName: "",
                                         identity: identity(50, 50, 1.8, nikonID: 7))
        XCTAssertNotEqual(a, b, "another lens on the same body is another key")
        let unknown = LensProfileOverrides.Key(cameraMake: "", cameraModel: "X", lensName: "", identity: identity(0, 0, 0))
        XCTAssertEqual(unknown.lens, "unknown lens")
    }

    func testAChoiceWinsOverTheAutomaticMatch() throws {
        // A lens the matcher can't place: an unknown 35 mm f/1.8 on a D750.
        let lens = identity(35, 35, 1.8)
        let chosen = try XCTUnwrap(Self.db.lenses.first { $0.model.contains("50mm f/1.8") && !$0.distortion.isEmpty })
        let key = LensProfileOverrides.Key(cameraMake: "Nikon", cameraModel: "D750", lensName: "", identity: lens)
        LensProfileOverrides.set(chosen.model, for: key)
        XCTAssertEqual(LensProfileOverrides.model(for: key), chosen.model)
        let match = try XCTUnwrap(LensProfileOverrides.match(cameraMake: "Nikon", cameraModel: "D750", lensName: "",
                                                             identity: lens, focal: 35, in: Self.db))
        XCTAssertEqual(match.lens.model, chosen.model)
        // Cleared, the automatic match is back (whatever it is).
        LensProfileOverrides.set(nil, for: key)
        let automatic = LensProfileOverrides.match(cameraMake: "Nikon", cameraModel: "D750", lensName: "",
                                                   identity: lens, focal: 35, in: Self.db)
        XCTAssertEqual(automatic?.lens.model, LensMatcher.match(cameraMake: "Nikon", cameraModel: "D750", lensName: "",
                                                                identity: lens, focal: 35, in: Self.db)?.lens.model)
    }

    func testAChoiceTheDatabaseLacksFallsBack() {
        let lens = identity(35, 35, 1.8)
        let key = LensProfileOverrides.Key(cameraMake: "Nikon", cameraModel: "D750", lensName: "", identity: lens)
        LensProfileOverrides.set("No Such Lens 12mm f/0.7", for: key)
        XCTAssertNil(LensProfileOverrides.manualMatch(model: "No Such Lens 12mm f/0.7", cameraMake: "Nikon",
                                                      cameraModel: "D750", identity: lens, in: Self.db))
        XCTAssertEqual(LensProfileOverrides.match(cameraMake: "Nikon", cameraModel: "D750", lensName: "",
                                                  identity: lens, focal: 35, in: Self.db)?.lens.model,
                       LensMatcher.match(cameraMake: "Nikon", cameraModel: "D750", lensName: "",
                                         identity: lens, focal: 35, in: Self.db)?.lens.model)
    }

    func testAnUnlistedBodyStillGetsTheProfile() throws {
        let chosen = try XCTUnwrap(Self.db.lenses.first { !$0.distortion.isEmpty })
        let match = try XCTUnwrap(LensProfileOverrides.manualMatch(model: chosen.model, cameraMake: "Acme",
                                                                   cameraModel: "Prototype 1", identity: identity(0, 0, 0),
                                                                   in: Self.db))
        XCTAssertEqual(match.lens.model, chosen.model)
        XCTAssertEqual(match.cropRatio, 1, accuracy: 1e-6, "a stand-in body at the lens's own calibration crop")
    }

    func testChoicesPutFittingLensesFirst() {
        let choices = LensProfileOverrides.choices(cameraMake: "Nikon", cameraModel: "D750", in: Self.db)
        XCTAssertFalse(choices.fitting.isEmpty)
        XCTAssertTrue(choices.fitting.contains { $0.maker.lowercased().contains("nikon") })
        XCTAssertTrue(Set(choices.fitting.map(\.model)).isDisjoint(with: choices.others.map(\.model)))
        let unknown = LensProfileOverrides.choices(cameraMake: "Acme", cameraModel: "Prototype 1", in: Self.db)
        XCTAssertTrue(unknown.fitting.isEmpty)
        XCTAssertEqual(unknown.others.count, choices.fitting.count + choices.others.count)
    }

    func testPickerMenuGroupsTheChoicesByMaker() {
        let choices = LensProfileOverrides.choices(cameraMake: "Nikon", cameraModel: "D750", in: Self.db)
        let menu = LensProfileOverrides.pickerMenu(cameraMake: "Nikon", cameraModel: "D750", in: Self.db)
        XCTAssertEqual(menu.fitting.flatMap(\.lenses).map(\.model).sorted(), choices.fitting.map(\.model).sorted())
        XCTAssertEqual(menu.others.flatMap(\.lenses).map(\.model).sorted(), choices.others.map(\.model).sorted())
        for groups in [menu.fitting, menu.others] {
            let makers = groups.map(\.maker)
            XCTAssertEqual(Set(makers).count, makers.count, "one group per maker")
            XCTAssertEqual(makers, makers.sorted { $0.lowercased() < $1.lowercased() }, "makers in alphabetical order")
            for group in groups {
                XCTAssertTrue(group.lenses.allSatisfy { $0.maker == group.maker })
                let models = group.lenses.map { $0.model.lowercased() }
                XCTAssertEqual(models, models.sorted(), "models in alphabetical order")
            }
        }
        XCTAssertEqual(LensProfileOverrides.pickerMenu(cameraMake: "Nikon", cameraModel: "D750", in: Self.db), menu,
                       "asking again gives the kept lists")
    }

    func testKeptChoicesBelongToTheirDatabase() throws {
        let lens = try XCTUnwrap(Self.db.lenses.first { !$0.distortion.isEmpty })
        let tiny = LensfunDatabase(cameras: [], lenses: [lens], mountCompatibility: [:], version: "test")
        _ = LensProfileOverrides.choices(cameraMake: "Nikon", cameraModel: "D750", in: Self.db)
        let fromTiny = LensProfileOverrides.choices(cameraMake: "Nikon", cameraModel: "D750", in: tiny)
        XCTAssertEqual(fromTiny.fitting.map(\.model) + fromTiny.others.map(\.model), [lens.model],
                       "a different database is not answered from another's kept lists")
        let empty = LensfunDatabase(cameras: [], lenses: [], mountCompatibility: [:], version: "empty")
        XCTAssertTrue(LensProfileOverrides.pickerMenu(cameraMake: "Nikon", cameraModel: "D750", in: empty).others.isEmpty)
        XCTAssertGreaterThan(LensProfileOverrides.choices(cameraMake: "Nikon", cameraModel: "D750", in: Self.db)
                                .fitting.count, 1, "and back to the real database")
    }
}
