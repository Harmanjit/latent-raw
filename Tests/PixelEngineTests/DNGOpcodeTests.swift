import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore
import LensKit

/// A DNG's opcode lists (DNGOpcodes.swift) read from a synthetic file, and
/// turned into Latent's flat-field gain map and lens model
/// (DNGOpcodeCorrections.swift), then applied in a render only while the
/// switch is on.
final class DNGOpcodeTests: XCTestCase {
    typealias F = RawReconstructionFixtures

    // MARK: - Writing a synthetic DNG

    struct BigEndian {
        var data = Data()
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
        mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.bigEndian) { data.append(contentsOf: $0) } }
        mutating func f32(_ v: Float) { withUnsafeBytes(of: v.bitPattern.bigEndian) { data.append(contentsOf: $0) } }
    }

    static func opcode(_ id: UInt32, _ params: Data) -> Data {
        var w = BigEndian()
        w.u32(id); w.u32(0x0103_0000); w.u32(1); w.u32(UInt32(params.count))
        return w.data + params
    }

    static func list(_ ops: [Data]) -> Data {
        var w = BigEndian()
        w.u32(UInt32(ops.count))
        return ops.reduce(w.data, +)
    }

    static func gainMap(top: Int, left: Int, gains: [Float], pitch: Int = 2) -> Data {
        var w = BigEndian()
        for v in [top, left, 96, 128, 0, 1, pitch, pitch, 2, 2] { w.u32(UInt32(v)) }
        for v in [1.0, 1.0, 0.0, 0.0] { w.f64(v) }
        w.u32(1)
        for g in gains { w.f32(g) }
        return opcode(9, w.data)
    }

    static func warp(planes: [[Double]]) -> Data {
        var w = BigEndian()
        w.u32(UInt32(planes.count))
        for kr in planes { for v in kr + [0, 0] { w.f64(v) } }
        w.f64(0.5); w.f64(0.5)
        return opcode(1, w.data)
    }

    static func vignette(_ k: [Double]) -> Data {
        var w = BigEndian()
        for v in k + [0.5, 0.5] { w.f64(v) }
        return opcode(3, w.data)
    }

    /// A little-endian TIFF whose first directory is a preview
    /// (NewSubfileType 1) with the main image in a SubIFD, as camera DNGs
    /// are laid out, carrying the lists there.
    static func tiff(list2: Data, list3: Data) -> Data {
        var d = Data()
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func entry(_ tag: UInt16, _ type: UInt16, _ count: UInt32, _ value: UInt32) {
            u16(tag); u16(type); u32(count); u32(value)
        }
        d.append(contentsOf: [0x49, 0x49]); u16(42); u32(8)
        // IFD0 at 8: 2 + 2 * 12 + 4 = 30 bytes, so the SubIFD starts at 38.
        u16(2); entry(254, 4, 1, 1); entry(330, 4, 1, 38); u32(0)
        // SubIFD at 38: 2 + 3 * 12 + 4 = 42 bytes, so the lists start at 80.
        u16(3); entry(254, 4, 1, 0)
        entry(51009, 7, UInt32(list2.count), 80)
        entry(51022, 7, UInt32(list3.count), UInt32(80 + list2.count))
        u32(0)
        return d + list2 + list3
    }

    static var sampleTIFF: Data {
        tiff(list2: list([gainMap(top: 0, left: 0, gains: [1, 2, 1, 2]), gainMap(top: 0, left: 1, gains: [1, 1, 1, 1]),
                          gainMap(top: 1, left: 0, gains: [1, 1, 1, 1]), gainMap(top: 1, left: 1, gains: [1, 1, 1, 1]),
                          opcode(4, Data(count: 8))]),
             list3: list([warp(planes: [[1.001, 0.05, 0, 0], [1, 0.05, 0, 0], [0.999, 0.05, 0, 0]]),
                          vignette([0.3, 0, 0, 0, 0])]))
    }

    // MARK: - Reading

    func testReadsTheMainImagesLists() throws {
        let list = try DNGOpcodes.read(tiff: Self.sampleTIFF)
        XCTAssertEqual(list.gainMaps.count, 4)
        XCTAssertEqual(list.gainMaps[0].gains, [1, 2, 1, 2])
        XCTAssertEqual(list.gainMaps[1].left, 1)
        XCTAssertEqual(list.gainMaps[0].rowPitch, 2)
        XCTAssertEqual(list.warp?.planes.count, 3)
        XCTAssertEqual(list.warp?.planes[1].kr, [1, 0.05, 0, 0])
        XCTAssertEqual(list.vignette?.k, [0.3, 0, 0, 0, 0])
        XCTAssertEqual(list.unsupported, [4])
        XCTAssertFalse(list.fingerprint.isEmpty)
        XCTAssertEqual(list.gainMaps[0].gain(v: 0.5, h: 0.5, mapPlane: 0), 1.5, accuracy: 1e-6)
    }

    func testRefusesTruncatedAndForeignFiles() {
        XCTAssertThrowsError(try DNGOpcodes.read(tiff: Data("not a tiff at all".utf8)))
        let whole = Self.sampleTIFF
        XCTAssertThrowsError(try DNGOpcodes.read(tiff: whole.prefix(whole.count - 10)))
        // Lists with nothing Latent applies.
        let unsupported = Self.list([Self.opcode(4, Data(count: 8))])
        let list = try? DNGOpcodes.read(tiff: Self.tiff(list2: unsupported, list3: unsupported))
        XCTAssertEqual(list?.isEmpty, true)
        XCTAssertEqual(list?.unsupported, [4, 4])
    }

    // MARK: - Converting

    func testGainMapsBecomeAFlatFieldMap() throws {
        let list = try DNGOpcodes.read(tiff: Self.sampleTIFF)
        let map = try XCTUnwrap(DNGEmbeddedCorrections.gainMap(from: list.gainMaps, summary: F.summary(width: 128, height: 96)))
        XCTAssertEqual(map.width, 64)
        XCTAssertEqual(map.height, 48)
        XCTAssertTrue(map.fits(aspect: 128.0 / 96.0))
        // Red (the RGGB quad's top-left) rises from 1 to 2 across the frame.
        XCTAssertEqual(map.gain(x: 0, y: 10).x, 1, accuracy: 0.02)
        XCTAssertEqual(map.gain(x: 63, y: 10).x, 2, accuracy: 0.02)
        XCTAssertEqual(map.gain(x: 63, y: 10).y, 1, accuracy: 1e-6)
        XCTAssertEqual(map.gain(x: 63, y: 10).z, 1, accuracy: 1e-6)
    }

    func testWarpAndVignetteBecomeALensModel() throws {
        let list = try DNGOpcodes.read(tiff: Self.sampleTIFF)
        let lens = try XCTUnwrap(DNGEmbeddedCorrections.lens(warp: list.warp, vignette: list.vignette, width: 128, height: 96))
        XCTAssertEqual(lens.profileName, DNGEmbeddedCorrections.profileName)
        // Distortion: the DNG's 1 + 0.05 r² with r in half diagonals (80
        // px) is 1 + 0.018 ru² with ru in half short sides (48 px).
        let d = try XCTUnwrap(lens.distortion)
        for ru: Float in [0.25, 0.75, 1.25] {
            let r = Double(ru) * 48 / 80
            XCTAssertEqual(d.factor(atUndistortedRadius: ru), Float(1 + 0.05 * r * r), accuracy: 1e-3)
        }
        // Chromatic aberration: red reads 0.1 % out, blue 0.1 % in.
        let tca = try XCTUnwrap(lens.tca)
        XCTAssertEqual(tca.red.z, 1.001, accuracy: 2e-4)
        XCTAssertEqual(tca.blue.z, 0.999, accuracy: 2e-4)
        // Vignetting: Latent divides by its polynomial, the DNG multiplies.
        let v = try XCTUnwrap(lens.vignetting)
        for r: Float in [0.3, 0.7, 1.0] {
            let x = r * r
            XCTAssertEqual(1 / (1 + v.k1 * x + v.k2 * x * x + v.k3 * x * x * x), 1 + 0.3 * x, accuracy: 0.01)
        }
        XCTAssertLessThanOrEqual(lens.autoScale, 1.0001)
    }

    // MARK: - In a session

    /// The corrections apply only while switched on: the lens model then
    /// replaces the profile, and the gain map brightens the render.
    func testCorrectionsApplyOnlyWhileSwitchedOn() throws {
        let gpu = try GPUContext()
        let file = try F.file(width: 128, height: 96) { _, _ in SIMD3(200, 300, 250) }
        var list = try DNGOpcodes.read(tiff: Self.sampleTIFF)
        // Every CFA position doubled, so all three channels brighten.
        list.gainMaps = [(0, 0), (0, 1), (1, 0), (1, 1)].map { pos in
            DNGGainMap(top: pos.0, left: pos.1, bottom: 96, right: 128, plane: 0, planes: 1, rowPitch: 2, colPitch: 2,
                       pointsV: 2, pointsH: 2, spacingV: 1, spacingH: 1, originV: 0, originH: 0, mapPlanes: 1,
                       gains: [2, 2, 2, 2])
        }
        list.fingerprint = "test-every-position-doubled"
        file.dngOpcodes = list
        let session = try ImageSession(file: file, gpu: gpu)
        XCTAssertTrue(session.hasEmbeddedDNGCorrections)
        XCTAssertEqual(session.dngCorrections?.summaryDescription,
                       "lens shading, vignetting, distortion, chromatic aberration")

        var off = EditParameters()
        off.lensDistortion = false; off.lensTCA = false; off.lensVignetting = false
        var on = off
        on.embeddedDNGCorrections = true
        XCTAssertNil(session.lensCorrection(for: off))
        XCTAssertEqual(session.lensCorrection(for: on)?.profileName, DNGEmbeddedCorrections.profileName)
        XCTAssertNil(session.embeddedGainMapTexture(for: off))
        XCTAssertNotNil(session.embeddedGainMapTexture(for: on))

        let pipeline = RenderPipeline(gpu: gpu)
        func mean(_ p: EditParameters) throws -> Float {
            let px = try F.floats(pipeline.render(session, parameters: p), gpu: gpu)
            var sum: Float = 0
            for i in stride(from: 0, to: px.count, by: 4) { sum += px[i] + px[i + 1] + px[i + 2] }
            return sum / Float(px.count / 4)
        }
        XCTAssertGreaterThan(try mean(on), try mean(off) * 1.1)

        // Stored only while on.
        XCTAssertFalse(try EditStack(parameters: off).encodeJSON().contains("\"embedded\""))
        let json = try EditStack(parameters: on).encodeJSON()
        XCTAssertTrue(json.contains("\"embedded\":true"))
        XCTAssertTrue(try EditStack.decode(json: json).parameters().embeddedDNGCorrections)
    }

    func testOnlyDNGFilesAreLookedIn() {
        XCTAssertTrue(DNGOpcodes.mayHaveOpcodes(path: "/x/IMG_0001.DNG"))
        XCTAssertFalse(DNGOpcodes.mayHaveOpcodes(path: "/x/DSC_0001.NEF"))
    }
}
