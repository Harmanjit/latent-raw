import XCTest
import simd
import ColorKit
@testable import PixelEngine
@testable import RawCore

/// Profiles: reading DCP files, the colour maths that turns one into a
/// camera matrix and tables, Latent's own looks, storing the choice in an
/// edit, and what the colour kernel does with all of it.
final class CameraProfileTests: XCTestCase {

    // MARK: - A DCP writer, for tests

    /// One IFD entry: tag, TIFF type and its values.
    enum Value {
        case ascii(String)
        case short([UInt16])
        case long([UInt32])
        case srational([Float])
        case float([Float])
    }

    /// A little-endian "IIRC" file holding `tags`.
    static func dcp(_ tags: [(Int, Value)]) -> Data {
        let sorted = tags.sorted { $0.0 < $1.0 }
        var header = Data([0x49, 0x49, 0x52, 0x43])
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        header += le32(8)
        let ifdSize = 2 + sorted.count * 12 + 4
        var extra = Data()
        var ifd = le16(UInt16(sorted.count))
        for (tag, value) in sorted {
            let type: UInt16, count: Int, bytes: Data
            switch value {
            case .ascii(let s):
                type = 2; bytes = Data(s.utf8) + Data([0]); count = bytes.count
            case .short(let v):
                type = 3; count = v.count; bytes = v.reduce(Data()) { $0 + le16($1) }
            case .long(let v):
                type = 4; count = v.count; bytes = v.reduce(Data()) { $0 + le32($1) }
            case .srational(let v):
                type = 10; count = v.count
                bytes = v.reduce(Data()) { d, f in
                    d + le32(UInt32(bitPattern: Int32((f * 10000).rounded()))) + le32(10000)
                }
            case .float(let v):
                type = 11; count = v.count; bytes = v.reduce(Data()) { $0 + le32($1.bitPattern) }
            }
            ifd += le16(UInt16(tag)) + le16(type) + le32(UInt32(count))
            if bytes.count <= 4 {
                ifd += bytes + Data(repeating: 0, count: 4 - bytes.count)
            } else {
                ifd += le32(UInt32(8 + ifdSize + extra.count))
                extra += bytes
                if extra.count % 2 == 1 { extra += Data([0]) }
            }
        }
        ifd += le32(0)
        return header + ifd + extra
    }

    static func rows(_ m: simd_float3x3) -> [Float] {
        (0..<3).flatMap { r in (0..<3).map { c in m[c][r] } }
    }

    /// XYZ -> camera for a camera whose RGB is exactly linear Rec.2020.
    static let rec2020Camera = ColorKit.rec2020ToXYZ.inverse
    /// White-balanced camera -> XYZ D50 for the same camera.
    static let rec2020Forward = ColorKit.bradfordAdaptation(from: ColorKit.d65XYZ, to: ColorKit.d50XYZ)
        * ColorKit.rec2020ToXYZ

    static func fullProfile() -> Data {
        let hue = 6, sat = 2
        var hueSat: [Float] = []
        for _ in 0..<hue { for _ in 0..<sat { hueSat += [10, 1, 1] } }
        var look: [Float] = []
        for _ in 0..<2 { for _ in 0..<hue { for s in 0..<sat { look += [0, s == 0 ? 1 : 0.5, 1] } } }
        return dcp([
            (50708, .ascii("Testcam X1")),
            (50936, .ascii("Testcam Standard")),
            (50721, .srational(rows(rec2020Camera))),
            (50722, .srational(rows(rec2020Camera))),
            (50778, .short([17])),
            (50779, .short([21])),
            (50964, .srational(rows(rec2020Forward))),
            (50965, .srational(rows(rec2020Forward))),
            (50937, .long([UInt32(hue), UInt32(sat), 1])),
            (50938, .float(hueSat)),
            (50939, .float(hueSat)),
            (50981, .long([UInt32(hue), UInt32(sat), 2])),
            (50982, .float(look)),
            (51108, .long([1])),
            (50940, .float([0, 0, 0.25, 0.4, 1, 1])),
            (51109, .srational([0.25])),
        ])
    }

    // MARK: - Parsing

    func testParsesEveryTag() throws {
        let p = try DCPProfile(data: Self.fullProfile())
        XCTAssertEqual(p.name, "Testcam Standard")
        XCTAssertEqual(p.uniqueCameraModel, "Testcam X1")
        XCTAssertEqual(p.calibration1.illuminant, 17)
        XCTAssertEqual(p.calibration2?.illuminant, 21)
        let cm = try XCTUnwrap(p.calibration1.colorMatrix)
        for c in 0..<3 { for r in 0..<3 { XCTAssertEqual(cm[c][r], Self.rec2020Camera[c][r], accuracy: 1e-4) } }
        XCTAssertNotNil(p.calibration2?.forwardMatrix)
        let map = try XCTUnwrap(p.calibration1.hueSatMap)
        XCTAssertEqual(map.hueDivisions, 6); XCTAssertEqual(map.satDivisions, 2); XCTAssertEqual(map.valDivisions, 1)
        let look = try XCTUnwrap(p.lookTable)
        XCTAssertEqual(look.valDivisions, 2)
        XCTAssertTrue(look.sRGBValueEncoding)
        XCTAssertTrue(p.hasToneCurve)
        XCTAssertEqual(p.toneCurveValue(0.25), 0.4, accuracy: 1e-5)
        XCTAssertEqual(p.toneCurveValue(0.125), 0.2, accuracy: 1e-5)
        XCTAssertEqual(p.baselineExposureOffset, 0.25, accuracy: 1e-4)
    }

    func testBigEndianFilesRead() throws {
        // The same minimal profile written big-endian, "MMCR".
        var d = Data([0x4D, 0x4D, 0x43, 0x52, 0, 0, 0, 8, 0, 1])
        d += Data([0xC6, 0x21, 0, 10, 0, 0, 0, 9, 0, 0, 0, 26])   // ColorMatrix1 at 26
        d += Data([0, 0, 0, 0])
        for v in [1, 0, 0, 0, 1, 0, 0, 0, 1] as [Int32] {
            d += withUnsafeBytes(of: v.bigEndian) { Data($0) }
            d += withUnsafeBytes(of: Int32(1).bigEndian) { Data($0) }
        }
        let p = try DCPProfile(data: d)
        XCTAssertEqual(p.calibration1.colorMatrix, matrix_identity_float3x3)
        XCTAssertNil(p.calibration2)
        XCTAssertFalse(p.hasToneCurve)
    }

    func testRefusesWhatIsntAProfile() {
        XCTAssertThrowsError(try DCPProfile(data: Data("hello, not a profile".utf8))) {
            XCTAssertEqual($0 as? DCPProfile.ParseError, .notAProfile)
        }
        XCTAssertThrowsError(try DCPProfile(data: Self.dcp([(50936, .ascii("No matrix"))]))) {
            XCTAssertEqual($0 as? DCPProfile.ParseError, .noColorMatrix)
        }
        // Cut short: the matrix's offset points past the end.
        let whole = Self.fullProfile()
        XCTAssertThrowsError(try DCPProfile(data: whole.prefix(whole.count / 2)))
        // A table whose size disagrees with its dimensions.
        XCTAssertThrowsError(try DCPProfile(data: Self.dcp([
            (50721, .srational(Self.rows(matrix_identity_float3x3))),
            (50937, .long([6, 2, 1])),
            (50938, .float([0, 1, 1])),
        ])))
    }

    // MARK: - Tables

    func testTableLookupInterpolatesAndWrapsHue() {
        // Hue shift = the sample's own hue / 10, so interpolation is visible.
        let t = HueSatTable(hue: 4, sat: 2) { h, _, _ in SIMD3(h / 10, 1, 1) }
        XCTAssertEqual(t.lookup(hue: 90, saturation: 0.5, value: 1).x, 9, accuracy: 1e-4)
        XCTAssertEqual(t.lookup(hue: 45, saturation: 0.5, value: 1).x, 4.5, accuracy: 1e-4)
        // Between the last sample (270) and the first (0, wrapping to 360).
        XCTAssertEqual(t.lookup(hue: 315, saturation: 0.5, value: 1).x, 13.5, accuracy: 1e-4)
        XCTAssertTrue(HueSatTable(hue: 6, sat: 3) { _, _, _ in HueSatTable.identityEntry }.isIdentity)
    }

    func testIdentityTableLeavesColoursAlone() {
        let t = HueSatTable(hue: 6, sat: 3) { _, _, _ in HueSatTable.identityEntry }
        for c in [SIMD3<Float>(0.2, 0.5, 0.9), SIMD3(3, 1, 0.1), SIMD3(0.4, 0.4, 0.4)] {
            let out = t.apply(toProPhoto: c)
            XCTAssertEqual(simd_length(out - c), 0, accuracy: 1e-5)
        }
    }

    // MARK: - Matrices

    func testWorkingAndProPhotoMapWhiteToWhite() {
        let w = ColorKit.workingToProPhoto * SIMD3<Float>(1, 1, 1)
        XCTAssertEqual(simd_length(w - SIMD3(1, 1, 1)), 0, accuracy: 1e-5)
        let back = ColorKit.proPhotoToWorking * (ColorKit.workingToProPhoto * SIMD3<Float>(0.2, 0.7, 0.1))
        XCTAssertEqual(simd_length(back - SIMD3(0.2, 0.7, 0.1)), 0, accuracy: 1e-5)
    }

    func testIlluminantWeightIsLinearInInverseTemperature() throws {
        let math = CameraProfileMath(profile: try DCPProfile(data: Self.fullProfile()))
        XCTAssertEqual(math.weight1(forTemperature: 2850), 1, accuracy: 1e-5)
        XCTAssertEqual(math.weight1(forTemperature: 6500), 0, accuracy: 1e-5)
        XCTAssertEqual(math.weight1(forTemperature: 2000), 1)
        XCTAssertEqual(math.weight1(forTemperature: 10000), 0)
        let mid: Float = 1 / ((1 / 2850 + 1 / 6500) / 2)
        XCTAssertEqual(math.weight1(forTemperature: mid), 0.5, accuracy: 1e-4)
    }

    /// A camera that sees exactly Rec.2020: whichever matrix the profile
    /// uses, its camera-to-working matrix is the identity.
    func testForwardAndColorMatrixPathsAgreeOnAKnownCamera() throws {
        let withForward = CameraProfileMath(profile: try DCPProfile(data: Self.fullProfile()))
        let colorOnly = CameraProfileMath(profile: try DCPProfile(data: Self.dcp([
            (50721, .srational(Self.rows(Self.rec2020Camera))), (50778, .short([21])),
        ])))
        for math in [withForward, colorOnly] {
            let m = try XCTUnwrap(math.cameraToWorking(multipliers: SIMD4(1, 1, 1, 1)))
            for c in 0..<3 { for r in 0..<3 {
                XCTAssertEqual(m[c][r], c == r ? 1 : 0, accuracy: 2e-3, "[\(c)][\(r)]")
            } }
        }
        // The white found for a neutral camera response is D65.
        let white = colorOnly.white(forCameraNeutral: SIMD3(1, 1, 1)).xy
        XCTAssertEqual(white.x, 0.3127, accuracy: 1e-3)
        XCTAssertEqual(white.y, 0.3290, accuracy: 1e-3)
    }

    func testCameraWhiteStaysWhiteForAnyBalance() throws {
        let math = CameraProfileMath(profile: try DCPProfile(data: Self.fullProfile()))
        for mul in [SIMD4<Float>(2.1, 1, 1.4, 1), SIMD4(1.3, 1, 2.6, 1)] {
            let m = try XCTUnwrap(math.cameraToWorking(multipliers: mul))
            XCTAssertEqual(simd_length(m * SIMD3<Float>(1, 1, 1) - SIMD3(1, 1, 1)), 0, accuracy: 1e-4)
        }
    }

    // MARK: - Latent's own profiles

    func testBuiltInProfilesKeepNeutralsNeutral() throws {
        for profile in BuiltInProfile.all {
            guard let look = profile.look else {
                XCTAssertEqual(profile.id, BuiltInProfile.standardID)
                continue
            }
            for grey: Float in [0.05, 0.5, 2] {
                let out = look.apply(toProPhoto: SIMD3(repeating: grey))
                XCTAssertEqual(simd_length(out - SIMD3(repeating: grey)), 0, accuracy: grey * 2e-3, profile.name)
            }
        }
    }

    func testMonochromeProfilesMakeGreys() throws {
        let mono = BuiltInProfile.all.filter { $0.group == .monochrome }
        XCTAssertGreaterThanOrEqual(mono.count, 3)
        for profile in mono {
            let look = try XCTUnwrap(profile.look)
            for c in [SIMD3<Float>(0.8, 0.2, 0.1), SIMD3(0.1, 0.6, 0.2), SIMD3(0.2, 0.3, 0.9)] {
                let out = look.apply(toProPhoto: c)
                XCTAssertEqual(out.x, out.y, accuracy: 1e-5, profile.name)
                XCTAssertEqual(out.y, out.z, accuracy: 1e-5, profile.name)
            }
        }
        // A red filter renders red lighter than a green filter does.
        let red = try XCTUnwrap(BuiltInProfile.named("latent:mono-red")?.look)
        let green = try XCTUnwrap(BuiltInProfile.named("latent:mono-green")?.look)
        let rose = ColorKit.workingToProPhoto * SIMD3<Float>(0.7, 0.15, 0.1)
        XCTAssertGreaterThan(red.apply(toProPhoto: rose).x, green.apply(toProPhoto: rose).x * 1.3)
    }

    func testIDsAreUniqueAndStable() {
        let ids = BuiltInProfile.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        // Stored in edits: these must never change.
        for id in ["latent:standard", "latent:neutral", "latent:flat", "latent:vivid", "latent:portrait",
                   "latent:landscape", "latent:mono", "latent:mono-red"] {
            XCTAssertNotNil(BuiltInProfile.named(id), id)
        }
    }

    // MARK: - The stored choice

    func testChoiceIsStoredOnlyWhenItMeansSomething() {
        XCTAssertNil(ProfileChoice(id: BuiltInProfile.standardID, name: "Latent Standard").sanitized)
        XCTAssertNil(ProfileChoice(id: "", name: "").sanitized)
        XCTAssertNil(ProfileChoice(id: "latent:vivid", name: "Vivid", amount: 1).sanitized?.amount)
        XCTAssertEqual(ProfileChoice(id: "latent:vivid", name: "Vivid", amount: 5).sanitized?.amount, 2)
        XCTAssertEqual(ProfileChoice(id: "latent:mono", name: "Monochrome", amount: 1.5).sanitized?.effectiveAmount, 1)
        XCTAssertEqual(ProfileChoice(id: "latent:vivid", name: "Vivid", amount: .nan).sanitized?.effectiveAmount, 1)
        XCTAssertNil(ProfileChoice(id: "latent:neutral", name: "Latent Neutral", amount: 0.3).sanitized?.amount,
                     "basic profiles have no amount")
        XCTAssertNil(ProfileChoice(id: "dcp:a.dcp", name: "A", toneCurve: false).sanitized?.toneCurve)
        XCTAssertEqual(ProfileChoice(id: "dcp:a.dcp", name: "A", toneCurve: true).sanitized?.toneCurve, true)
    }

    func testEditWithoutProfileEncodesAsBefore() throws {
        let json = try EditStack(parameters: EditParameters()).encodeJSON()
        XCTAssertFalse(json.contains("profile"), "an edit that never chose a profile mustn't change on disk")
        var standard = EditParameters()
        standard.profile = ProfileChoice(id: BuiltInProfile.standardID, name: "Latent Standard")
        XCTAssertEqual(try EditStack(parameters: standard).encodeJSON(), json)
    }

    func testProfileSurvivesSaveAndReload() throws {
        var p = EditParameters()
        p.profile = ProfileChoice(id: "latent:portrait", name: "Portrait", amount: 0.6)
        let reloaded = try EditStack.decode(json: EditStack(parameters: p).encodeJSON()).parameters()
        XCTAssertEqual(reloaded.profile, p.profile)
        XCTAssertEqual(reloaded, p)
        var other = p
        other.profile?.amount = 0.7
        XCTAssertNotEqual(other, p, "a profile change is an edit: it re-renders and records a step")

        var d = EditParameters()
        d.profile = ProfileChoice(id: "dcp:Testcam Standard.dcp", name: "Testcam Standard", toneCurve: true)
        XCTAssertEqual(try EditStack.decode(json: EditStack(parameters: d).encodeJSON()).parameters().profile, d.profile)

        // An old stack has no profile key and loads as Standard.
        let old = #"{"modules":{"exposure":{"ev":0.5}},"process":"1.0","schema":1}"#
        XCTAssertNil(try EditStack.decode(json: old).parameters().profile)
    }

    func testProfileTravelsAsItsOwnGroup() {
        var p = EditParameters()
        p.profile = ProfileChoice(id: "latent:vivid", name: "Vivid")
        let stack = EditStack(parameters: p)
        XCTAssertTrue(stack.presentGroups.contains(.profile))
        XCTAssertEqual(stack.restricted(to: [.profile]).modules.profile, p.profile)
        XCTAssertNil(stack.restricted(to: [.tone]).modules.profile)
        XCTAssertTrue(EditGroup.lookGroups.contains(.profile))
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(parameters: EditParameters()), to: stack), "Profile")
    }

    // MARK: - The library

    func makeLibrary() throws -> CameraProfileLibrary {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-profiles-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return CameraProfileLibrary(directory: dir)
    }

    func write(_ data: Data, named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    func testImportCopiesAndListsProfiles() throws {
        let library = try makeLibrary()
        let source = try write(Self.fullProfile(), named: "Testcam.dcp")
        let entry = try library.importProfile(from: source)
        XCTAssertEqual(entry.id, "dcp:Testcam.dcp")
        XCTAssertEqual(entry.name, "Testcam Standard")
        XCTAssertTrue(entry.hasToneCurve)
        XCTAssertEqual(library.entries().map(\.id), ["dcp:Testcam.dcp"])
        XCTAssertNotNil(library.profile(id: entry.id))

        // The same bytes again: the same profile, no copy.
        XCTAssertEqual(try library.importProfile(from: source).id, entry.id)
        // Different bytes with the same name: a numbered copy.
        let other = try write(Self.dcp([(50721, .srational(Self.rows(matrix_identity_float3x3)))]), named: "Testcam.dcp")
        XCTAssertEqual(try library.importProfile(from: other).id, "dcp:Testcam 2.dcp")
        XCTAssertEqual(library.entries().count, 2)

        // Not a profile: refused, nothing copied.
        let junk = try write(Data("junk".utf8), named: "Junk.dcp")
        XCTAssertThrowsError(try library.importProfile(from: junk))
        XCTAssertEqual(library.entries().count, 2)

        // An id is only ever a file in the folder.
        XCTAssertNil(library.profile(id: "dcp:../secret.dcp"))
        XCTAssertNil(library.profile(id: "dcp:missing.dcp"))
    }

    func testCameraMatching() {
        XCTAssertTrue(CameraProfileLibrary.matches(uniqueCameraModel: "Nikon D750", cameraMake: "Nikon", cameraModel: "D750"))
        XCTAssertTrue(CameraProfileLibrary.matches(uniqueCameraModel: "Sony ILCE-7M3", cameraMake: "Sony", cameraModel: "ILCE-7M3"))
        XCTAssertTrue(CameraProfileLibrary.matches(uniqueCameraModel: "NIKON CORPORATION NIKON D750",
                                                   cameraMake: "Nikon", cameraModel: "D750"))
        XCTAssertFalse(CameraProfileLibrary.matches(uniqueCameraModel: "Nikon D7500", cameraMake: "Nikon", cameraModel: "D750"))
        XCTAssertFalse(CameraProfileLibrary.matches(uniqueCameraModel: nil, cameraMake: "Nikon", cameraModel: "D750"))
    }

    // MARK: - Rendering

    struct Renderer {
        let gpu: GPUContext
        let session: ImageSession
        let pipeline: RenderPipeline

        func pixels(_ p: EditParameters) throws -> [Float] {
            let tex = try pipeline.render(session, scale: .binned(quads: 4), parameters: p, output: .file(.sRGB))
            return try TextureReadback.float16Pixels(of: tex, gpu: gpu).map { Float($0) }
        }
    }

    func renderer(library: CameraProfileLibrary? = nil) throws -> Renderer {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: try TestAssets.d750Path()), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        if let library { pipeline.profileLibrary = library }
        return Renderer(gpu: gpu, session: session, pipeline: pipeline)
    }

    static func worst(_ a: [Float], _ b: [Float]) -> Float {
        zip(a, b).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    static func meanChroma(_ px: [Float]) -> Float {
        var total: Float = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            total += max(px[i], px[i + 1], px[i + 2]) - min(px[i], px[i + 1], px[i + 2])
        }
        return total / Float(px.count / 4)
    }

    func testInactiveProfilesRenderExactlyAsBefore() throws {
        let r = try renderer(library: try makeLibrary())
        let plain = try r.pixels(EditParameters())
        var standard = EditParameters()
        standard.profile = ProfileChoice(id: BuiltInProfile.standardID, name: "Latent Standard")
        XCTAssertTrue(try r.pixels(standard) == plain, "Standard is the old rendering, bit for bit")
        var missing = EditParameters()
        missing.profile = ProfileChoice(id: "dcp:Not here.dcp", name: "Not here")
        XCTAssertTrue(try r.pixels(missing) == plain, "a DCP that isn't on this Mac falls back to Standard")
        var none = EditParameters()
        none.profile = ProfileChoice(id: "latent:vivid", name: "Vivid", amount: 0)
        XCTAssertLessThan(Self.worst(try r.pixels(none), plain), 2e-3, "a look at 0% changes nothing")
    }

    func testCreativeProfilesChangeTheImage() throws {
        let r = try renderer()
        let plain = try r.pixels(EditParameters())

        var mono = EditParameters()
        mono.profile = ProfileChoice(id: "latent:mono", name: "Monochrome")
        let grey = try r.pixels(mono)
        XCTAssertLessThan(Self.meanChroma(grey), 0.004, "Monochrome is grey")
        XCTAssertGreaterThan(Self.meanChroma(plain), 0.02)

        var vivid = EditParameters()
        vivid.profile = ProfileChoice(id: "latent:vivid", name: "Vivid")
        let vivid100 = Self.meanChroma(try r.pixels(vivid))
        XCTAssertGreaterThan(vivid100, Self.meanChroma(plain) * 1.08)
        vivid.profile?.amount = 2
        XCTAssertGreaterThan(Self.meanChroma(try r.pixels(vivid)), vivid100, "more Amount, more look")

        var flat = EditParameters()
        flat.profile = ProfileChoice(id: "latent:flat", name: "Latent Flat")
        let flatPixels = try r.pixels(flat)
        func spread(_ px: [Float]) -> Float {
            let g = stride(from: 0, to: px.count, by: 4).map { px[$0 + 1] }.sorted()
            return g[g.count * 95 / 100] - g[g.count * 5 / 100]
        }
        XCTAssertLessThan(spread(flatPixels), spread(plain), "Flat has less contrast")
    }

    func testImportedProfileDrivesTheRender() throws {
        let library = try makeLibrary()
        let r = try renderer(library: library)
        let xyzToCamera = try XCTUnwrap(r.session.profile?.xyzToCamera)
        let plain = try r.pixels(EditParameters())

        // The camera's own matrix as a single-illuminant profile: the
        // picture stays close to Latent's (the two differ only in how the
        // white is adapted).
        let matrixOnly = try write(Self.dcp([
            (50721, .float(Self.rows(xyzToCamera))), (50778, .short([21])),
            (50708, .ascii("Nikon D750")),
        ]), named: "Matrix.dcp")
        let entry = try library.importProfile(from: matrixOnly)
        var p = EditParameters()
        p.profile = ProfileChoice(id: entry.id, name: entry.name)
        let viaDCP = try r.pixels(p)
        let mean = zip(viaDCP, plain).reduce(Float(0)) { $0 + abs($1.0 - $1.1) } / Float(plain.count)
        XCTAssertLessThan(mean, 0.03)
        XCTAssertGreaterThan(Self.worst(viaDCP, plain), 0, "and it really is a different path")

        // A HueSatMap turning every hue half way round changes colours, not greys.
        var table: [Float] = []
        for _ in 0..<6 { for _ in 0..<2 { table += [180, 1, 1] } }
        let shifted = try write(Self.dcp([
            (50721, .float(Self.rows(xyzToCamera))), (50778, .short([21])),
            (50937, .long([6, 2, 1])), (50938, .float(table)),
            (50940, .float([0, 0, 0.5, 0.8, 1, 1])),
        ]), named: "Shifted.dcp")
        let shiftedEntry = try library.importProfile(from: shifted)
        p.profile = ProfileChoice(id: shiftedEntry.id, name: shiftedEntry.name)
        let turned = try r.pixels(p)
        XCTAssertGreaterThan(Self.worst(turned, viaDCP), 0.1)

        // Its tone curve applies only when switched on, and brightens here.
        p.profile?.toneCurve = true
        let toned = try r.pixels(p)
        let before = turned.reduce(0, +), after = toned.reduce(0, +)
        XCTAssertGreaterThan(after, before * 1.05)
    }
}
