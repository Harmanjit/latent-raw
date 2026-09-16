import XCTest
@testable import LensKit
import RawCore

/// Lens identification: a profile for the wrong lens is worse than none.
/// Synthetic cases pin the rules; the real-file cases (skipped when the
/// files aren't in TestAssets) pin what each file we have actually gets.
final class LensMatchingTests: XCTestCase {
    static let db = LensfunDatabase.shared

    private func nikon(id: UInt8, lensID: UInt64 = 0, _ lo: Double, _ hi: Double,
                       _ apShort: Double, _ apLong: Double? = nil) -> LensIdentity {
        LensIdentity(make: "", makerNotesName: "", makerLensID: lensID, nikonLensID: id, nikonLensType: 0,
                     minFocal: lo, maxFocal: hi, maxApertureAtMinFocal: apShort,
                     maxApertureAtMaxFocal: apLong ?? apShort, cropFactor: 0)
    }

    private func lens(_ model: String) throws -> LensfunLens {
        try XCTUnwrap(Self.db.lenses.first { $0.model == model }, "\(model) not in the database")
    }

    // MARK: - Reading specs from names

    func testSpecsFromLensfunNames() {
        func check(_ name: String, _ lo: Float?, _ hi: Float?, _ a: Float?, _ b: Float?,
                   file: StaticString = #filePath, line: UInt = #line) {
            let s = LensSpec.parse(modelName: name)
            XCTAssertEqual(s.focal?.lowerBound, lo, "\(name) focal", file: file, line: line)
            XCTAssertEqual(s.focal?.upperBound, hi, "\(name) focal", file: file, line: line)
            XCTAssertEqual(s.apertureAtShortEnd, a, "\(name) aperture", file: file, line: line)
            XCTAssertEqual(s.apertureAtLongEnd, b, "\(name) aperture", file: file, line: line)
        }
        check("Nikon AF-S DX Nikkor 16-80mm f/2.8-4E ED VR", 16, 80, 2.8, 4)
        check("Nikon AF-S DX Zoom-Nikkor 17-55mm f/2.8G IF-ED", 17, 55, 2.8, 2.8)
        check("Nikon AF-S Nikkor 50mm f/1.4G 160", 50, 50, 1.4, 1.4)
        check("200-500mm F5.6 174", 200, 500, 5.6, 5.6)
        check("Tamron SP 35mm f/1.8 Di VC USD F012", 35, 35, 1.8, 1.8)   // not f/12
        check("Tokina AF 100mm f/2.8 AT-X Pro D M100 Macro", 100, 100, 2.8, 2.8) // "AF 100" isn't f/100
        check("Samyang 35mm T1.5 Cine Lens", 35, 35, 1.5, 1.5)
        check("Minolta MD 35mm 1/2.8", 35, 35, 2.8, 2.8)
        check("Summicron-M 1:2/50", 50, 50, 2, 2)
        check("Vario-Elmarit-SL 1:2.8-4/24-90 ASPH.", 24, 90, 2.8, 4)
        check("LUMIX G VARIO 100-300/F4.0-5.6II", 100, 300, 4, 5.6)
        check("Zeiss Touit 1.8/32", 32, 32, 1.8, 1.8)
        check("Viltrox AF 56/1.4 XF", 56, 56, 1.4, 1.4)
        check("XF18-55mmF2.8-4 R LM OIS", 18, 55, 2.8, 4)
        check("Canon PowerShot G12 & compatibles (Standard)", nil, nil, nil, nil)
        check("XF100-400mmF4.5-5.6 R LM OIS WR + 1.4x converter", nil, nil, nil, nil)
    }

    func testMostInterchangeableLensesHaveASpec() {
        // Compacts' "fixed lens" entries state no numbers, and lens +
        // converter combinations deliberately read as unknown. Nearly
        // everything else should have a spec, or the matcher can't vouch
        // for it. (The few left: a body cap lens, "Tokina AT-X 14-20 F2".)
        let interchangeable = Self.db.lenses.filter {
            $0.mounts.contains { $0.first?.isUppercase == true }
                && !$0.model.contains("+") && !$0.model.lowercased().contains("converter")
        }
        let withSpec = interchangeable.filter { $0.spec.focal != nil && $0.spec.apertureAtShortEnd != nil }
        XCTAssertGreaterThan(Double(withSpec.count) / Double(interchangeable.count), 0.99,
                             "unreadable: " + interchangeable.filter { $0.spec.focal == nil || $0.spec.apertureAtShortEnd == nil }
                                .map(\.model).joined(separator: " | "))
    }

    // MARK: - Specs must agree

    func testSpecsRuleOutOtherLenses() throws {
        // What a D200 reports for the AF-S DX 17-55mm f/2.8G: Nikon's
        // encoding reads 17mm back as 17.3 and f/2.8 as 2.83.
        let reported = nikon(id: 125, 17.3, 55, 2.83)
        XCTAssertEqual(LensMatcher.specAgreement(try lens("Nikon AF-S DX Zoom-Nikkor 17-55mm f/2.8G IF-ED"), reported), .agrees)
        // The lens the matcher used to pick: wrong range, and f/4 at 55mm.
        XCTAssertEqual(LensMatcher.specAgreement(try lens("Nikon AF-S DX Nikkor 16-80mm f/2.8-4E ED VR"), reported), .conflicts)
        XCTAssertEqual(LensMatcher.specAgreement(try lens("Nikon AF-S Zoom-Nikkor 17-35mm f/2.8D IF-ED"), reported), .conflicts)

        // f/1.8 vs f/2 is a third of a stop: a different lens.
        let fast35 = nikon(id: 232, 35.6, 35.6, 1.78)
        XCTAssertEqual(LensMatcher.specAgreement(try lens("Nikon AI-S Nikkor 35mm f/2"), fast35), .conflicts)
        XCTAssertEqual(LensMatcher.specAgreement(try lens("Nikon AF-S Nikkor 35mm f/1.8G ED"), fast35), .agrees)
    }

    func testD200Zoom17to55MatchesBySpecsAndByID() throws {
        for lensID: UInt64 in [0, 0x7D48_2B53_2424_8206] {
            let match = try XCTUnwrap(LensMatcher.match(
                cameraMake: "Nikon", cameraModel: "D200", lensName: "",
                identity: nikon(id: 125, lensID: lensID, 17.3, 55, 2.83), focal: 17, in: Self.db))
            XCTAssertEqual(match.lens.model, "Nikon AF-S DX Zoom-Nikkor 17-55mm f/2.8G IF-ED", "lens ID \(lensID)")
        }
    }

    func testThree35mmF18sNeedTheLensID() throws {
        // Specs alone fit Nikon's FX and DX 35mm f/1.8G and Tamron's SP 35mm
        // f/1.8: no match rather than a guess.
        XCTAssertNil(LensMatcher.match(cameraMake: "Nikon", cameraModel: "D750", lensName: "",
                                       identity: nikon(id: 232, 35.6, 35.6, 1.78), focal: 35, in: Self.db))
        // The 8-byte ID tells them apart (IDs from ExifTool's table).
        let cases: [(UInt64, String)] = [
            (0xE84C_4444_1414_DF0E, "Tamron SP 35mm f/1.8 Di VC USD F012"),
            (0xA54C_4444_1414_C006, "Nikon AF-S Nikkor 35mm f/1.8G ED"),
            (0x9F58_4444_1414_A106, "Nikon AF-S DX Nikkor 35mm f/1.8G"),
        ]
        for (lensID, model) in cases {
            let id = UInt8(lensID >> 56)
            let match = try XCTUnwrap(LensMatcher.match(
                cameraMake: "Nikon", cameraModel: "D750", lensName: "",
                identity: nikon(id: id, lensID: lensID, 35.6, 35.6, 1.78), focal: 35, in: Self.db), model)
            XCTAssertEqual(match.lens.model, model)
        }
    }

    func testAnIDOrNameTheDatabaseLacksMatchesNothing() {
        // A composite ID the table doesn't know, with a one-byte ID that
        // isn't in Lensfun either, falls back to specs, which here are
        // ambiguous (many 50mm f/1.8 lenses).
        XCTAssertNil(LensMatcher.match(cameraMake: "Nikon", cameraModel: "D750", lensName: "",
                                       identity: nikon(id: 7, lensID: 0x0754_5050_1414_0006, 50.4, 50.4, 1.78),
                                       focal: 50, in: Self.db))
        // The file names a lens that isn't in the database. The Nikkor
        // 17-55mm is the only lens with those specs, but it's not the lens.
        XCTAssertNil(LensMatcher.match(cameraMake: "Nikon", cameraModel: "D200", lensName: "Acme 17-55mm f/2.8 Wonder",
                                       identity: nikon(id: 0, 17, 55, 2.8), focal: 17, in: Self.db))
        // No specs and no name: nothing to go on.
        XCTAssertNil(LensMatcher.match(cameraMake: "Nikon", cameraModel: "D750", lensName: "",
                                       identity: nikon(id: 0, 0, 0, 0), focal: 50, in: Self.db))
    }

    func testCanonMakerNotesNameMatchesAndSpecsAloneDoNot() throws {
        let named = LensIdentity(make: "", makerNotesName: "EF 50mm f/1.4 USM", makerLensID: 198, nikonLensID: 0,
                                 nikonLensType: 0, minFocal: 50, maxFocal: 50, maxApertureAtMinFocal: 0,
                                 maxApertureAtMaxFocal: 0, cropFactor: 0)
        let match = try XCTUnwrap(LensMatcher.match(cameraMake: "Canon", cameraModel: "EOS 5D Mark II",
                                                    lensName: "", identity: named, focal: 50, in: Self.db))
        XCTAssertEqual(match.lens.model, "Canon EF 50mm f/1.4 USM")
        XCTAssertEqual(match.lens.cropFactor, 1, "full-frame calibration for a full-frame body")

        let unnamed = LensIdentity(make: "", makerNotesName: "", makerLensID: 0, nikonLensID: 0, nikonLensType: 0,
                                   minFocal: 50, maxFocal: 50, maxApertureAtMinFocal: 0, maxApertureAtMaxFocal: 0,
                                   cropFactor: 0)
        XCTAssertNil(LensMatcher.match(cameraMake: "Canon", cameraModel: "EOS 5D Mark II", lensName: "",
                                       identity: unnamed, focal: 50, in: Self.db))
    }

    func testCompactsBuiltInLensStillMatches() throws {
        // A compact's lens names no numbers, but its body can't carry another.
        let g12 = LensIdentity(make: "", makerNotesName: "", makerLensID: 0, nikonLensID: 0, nikonLensType: 0,
                               minFocal: 6.1, maxFocal: 30.5, maxApertureAtMinFocal: 2.8, maxApertureAtMaxFocal: 4.5,
                               cropFactor: 0)
        let match = try XCTUnwrap(LensMatcher.match(cameraMake: "Canon", cameraModel: "PowerShot G12", lensName: "",
                                                    identity: g12, focal: 6.1, in: Self.db))
        XCTAssertTrue(match.lens.model.contains("G12"), match.lens.model)
    }

    // MARK: - Real files

    /// Before this fix, the D200 brackets matched the 16-80mm f/2.8-4E and
    /// the golden D750 file the AI-S 35mm f/2. Both were wrong.
    func testRealFilesMatchTheirLenses() throws {
        let cases: [(String, String?)] = [
            ("merge/empa-crete-seashore-1/DSC_0044.NEF", "Nikon AF-S DX Zoom-Nikkor 17-55mm f/2.8G IF-ED"),
            ("merge/empa-market-mires-2/DSC_0039.NEF", "Nikon AF-S DX Zoom-Nikkor 17-55mm f/2.8G IF-ED"),
            ("golden_nikon_d750_cc0.nef", "Tamron SP 35mm f/1.8 Di VC USD F012"),
            ("HSB_2615.NEF", "Nikon AF-S Nikkor 50mm f/1.4G"),
            ("HSB_2639.NEF", "Nikon AF-S Nikkor 50mm f/1.4G"),
            ("HSB_6548.NEF", "Nikon AF-S Nikkor 50mm f/1.4G"),
            ("HSB_6664.NEF", "Tokina AF 100mm f/2.8 AT-X Pro D M100 Macro"),
            ("nikon_d750_sample.nef", "Tokina AF 100mm f/2.8 AT-X Pro D M100 Macro"),
            ("merge/ihrke-tripod-bracket/IMG_7224.CR2", "Canon EF 50mm f/1.4 USM"),
        ]
        var ran = 0
        for (name, expected) in cases {
            let path = TestAssets.path(name)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let s = try RawFile(path: path).summary
            let match = LensMatcher.match(cameraMake: s.cameraMake, cameraModel: s.cameraModel, lensName: s.lensModel,
                                          identity: s.lens, focal: s.focalLength, in: Self.db)
            XCTAssertEqual(match?.lens.model, expected, name)
            if let match { XCTAssertEqual(match.lens.cropFactor, match.camera.cropFactor, accuracy: 0.05, "\(name): native calibration") }
            ran += 1
        }
        try XCTSkipIf(ran == 0, "none of the real test files are in TestAssets")
    }
}
