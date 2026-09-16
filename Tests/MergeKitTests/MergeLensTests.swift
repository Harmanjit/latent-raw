import ImageIO
import PixelEngine
import RawCore
import XCTest
@testable import MergeKit

/// A merge keeps its reference frame's lens: in the EXIF and DNG lens tags
/// for other apps, and whole in the recipe for Latent, so the merged DNG
/// matches the same lens profile as the raw it came from.
final class MergeLensTests: XCTestCase {
    nonisolated(unsafe) private var folder: URL!

    override func setUpWithError() throws { folder = try Fixtures.temporaryFolder() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// A Canon raw as LibRaw reads it: the lens named only in the maker
    /// notes, a Canon lens ID, a prime's range and no apertures.
    static let canonLens = LensIdentity(
        make: "", makerNotesName: "EF 50mm f/1.4 USM", makerLensID: 198, nikonLensID: 0, nikonLensType: 0,
        minFocal: 50, maxFocal: 50, maxApertureAtMinFocal: 0, maxApertureAtMaxFocal: 0, cropFactor: 0)
    /// A Nikon D200 raw: no name at all, Nikon's lens ID and type, the
    /// range, apertures as LibRaw's Floats and the DX crop factor.
    static let nikonLens = LensIdentity(
        make: "", makerNotesName: "", makerLensID: 9_027_513_089_152_811_526, nikonLensID: 125, nikonLensType: 6,
        minFocal: 17, maxFocal: 55, maxApertureAtMinFocal: Double(Float(2.8)),
        maxApertureAtMaxFocal: Double(Float(2.8)), cropFactor: Double(Float(1.4705882)))

    private func metadata(lensModel: String = "", lens: LensIdentity, focalLength: Double = 35) throws -> MergeDNGMetadata {
        try MergeDNGMetadata(summary: Fixtures.summary(lensModel: lensModel, lens: lens, focalLength: focalLength),
                             cameraToXYZ: Fixtures.d750CamXYZ, softwareVersion: "0.9")
    }

    private func write(_ metadata: MergeDNGMetadata, recipe: MergeRecipe = Fixtures.recipe(),
                       name: String) throws -> MergeDNGWriteResult {
        let (width, height) = (160, 120)
        var writer = LinearRawDNGWriter(tileSize: 64)
        writer.availableCapacity = { _ in nil }
        return try writer.write(.buffer(Fixtures.pixels(width: width, height: height, maximum: 2),
                                        width: width, height: height),
                                maximum: 2, metadata: metadata, recipe: recipe, preview: Fixtures.previewImage(),
                                to: folder.appendingPathComponent(name))
    }

    private func reopen(_ url: URL) throws -> RawSummary {
        let descriptor = open(url.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        return try RawFile(fileDescriptor: descriptor, metadataOnly: true).summary
    }

    // MARK: - Metadata

    func testMetadataKeepsTheWholeLens() throws {
        let m = try metadata(lens: Self.nikonLens, focalLength: 24)
        XCTAssertEqual(m.lens, LinearMergeInfo.Lens(model: "", identity: Self.nikonLens))
        XCTAssertEqual(m.focalLength, 24)
    }

    func testLensNamePrefersEXIFThenMakerNotesThenTheRange() {
        func name(_ model: String = "", notes: String = "", _ minFocal: Double = 0, _ maxFocal: Double = 0,
                  _ wide: Double = 0, _ long: Double = 0) -> String? {
            MergeDNGMetadata.lensName(model: model, identity: LensIdentity(
                make: "", makerNotesName: notes, makerLensID: 0, nikonLensID: 0, nikonLensType: 0,
                minFocal: minFocal, maxFocal: maxFocal, maxApertureAtMinFocal: wide, maxApertureAtMaxFocal: long,
                cropFactor: 0))
        }
        XCTAssertEqual(name("AF-S NIKKOR 24-70mm f/2.8E ED VR", notes: "other", 24, 70, 2.8, 2.8),
                       "AF-S NIKKOR 24-70mm f/2.8E ED VR")
        XCTAssertEqual(name(" ", notes: "EF 50mm f/1.4 USM", 50, 50), "EF 50mm f/1.4 USM", "blank EXIF name skipped")
        XCTAssertEqual(name(notes: "", 17, 55, Double(Float(2.8)), Double(Float(2.8))), "17-55mm f/2.8")
        XCTAssertEqual(name(notes: "", 18, 200, 3.5, 5.6), "18-200mm f/3.5-5.6")
        XCTAssertEqual(name(notes: "", 50, 50, 1.4, 1.4), "50mm f/1.4")
        XCTAssertEqual(name(notes: "", 50, 50), "50mm", "no apertures: the focal length alone")
        XCTAssertEqual(name(notes: "", 10.5, 0, 2.8), "10.5mm f/2.8", "no long end: a prime")
        XCTAssertNil(name())
    }

    func testLensSpecificationKeepsUnknownsAsZero() {
        XCTAssertEqual(MergeDNGMetadata.lensSpecification(for: Self.canonLens),
                       .init(minFocalLength: 50, maxFocalLength: 50, maxApertureAtMinFocal: 0, maxApertureAtMaxFocal: 0))
        XCTAssertEqual(MergeDNGMetadata.lensSpecification(for: Self.nikonLens)?.maxFocalLength, 55)
        let nothing = LensIdentity(make: "", makerNotesName: "", makerLensID: 0, nikonLensID: 0, nikonLensType: 0,
                                   minFocal: 0, maxFocal: 0, maxApertureAtMinFocal: 2.8, maxApertureAtMaxFocal: 0,
                                   cropFactor: 0)
        XCTAssertNil(MergeDNGMetadata.lensSpecification(for: nothing), "no focal range, no tag")
    }

    func testUnknownLensValuesAreWrittenAsZeroOverZero() throws {
        let tags = try DNGTagValues(metadata: metadata(lens: Self.canonLens), normalisation: .init(maximum: 1),
                                    width: 10, height: 10)
        XCTAssertEqual(tags.lensSpecification, [TIFFRational(5000, 100), TIFFRational(5000, 100),
                                                TIFFRational(0, 0), TIFFRational(0, 0)])
        XCTAssertEqual(tags.lensModel, "EF 50mm f/1.4 USM")
        XCTAssertNil(tags.lensMake, "the raw didn't say")
    }

    // MARK: - Recipe

    func testRecipeLensRoundTripsAndOldRecipesHaveNone() throws {
        var recipe = Fixtures.recipe()
        recipe.lens = .init(model: "", identity: Self.nikonLens)
        XCTAssertEqual(try MergeRecipe(jsonData: recipe.jsonData()), recipe)
        let xmp = try MergeXMP.packet(for: recipe)
        XCTAssertEqual(try MergeXMP.recipe(fromXMP: xmp)?.lens, recipe.lens)
        XCTAssertEqual(LinearMergeInfo.parse(xmpPacket: Data(xmp.utf8))?.lens, recipe.lens,
                       "RawCore reads what MergeKit writes")

        let old = #"{"version":1,"kind":"hdr","algorithmVersion":"1","clipLevel":8,"lensApplied":false,"baselineShift":0,"reference":1,"options":{},"sources":[]}"#
        XCTAssertNil(try MergeRecipe(jsonData: Data(old.utf8)).lens)
    }

    func testWriterFillsTheRecipeLensFromTheMetadata() throws {
        let reference = try Fixtures.summary(lensModel: "", lens: Self.canonLens)
        let m = try MergeDNGMetadata(summary: reference, cameraToXYZ: Fixtures.d750CamXYZ, softwareVersion: "0.9")
        let result = try write(m, name: "filled.dng")
        XCTAssertEqual(result.recipe.lens, .init(model: "", identity: Self.canonLens))
        // What a merge hands the app for the sidecar before writing is the same recipe.
        XCTAssertEqual(Fixtures.recipe().normalised(by: result.normalisation).withLens(of: reference), result.recipe)

        // A recipe that already has a lens keeps it.
        var recipe = Fixtures.recipe()
        recipe.lens = .init(model: "Mine", identity: Self.nikonLens)
        XCTAssertEqual(try write(metadata(lens: Self.canonLens), recipe: recipe, name: "kept.dng").recipe.lens,
                       recipe.lens)
    }

    // MARK: - Reading the file back

    /// What LibRaw itself reads from the lens tags, with no recipe lens to
    /// stand in for it (a recipe from before the lens was recorded).
    func testLibRawReadsTheLensTags() throws {
        var m = try Fixtures.metadata()
        XCTAssertNil(m.lens)
        m.lensSpecification = .init(minFocalLength: 17, maxFocalLength: 55, maxApertureAtMinFocal: 2.8,
                                    maxApertureAtMaxFocal: 0)
        let s = try reopen(write(m, name: "tags.dng").url)
        XCTAssertNil(s.mergeInfo?.lens)
        XCTAssertEqual(s.lensModel, "AF-S NIKKOR 24-70mm f/2.8E ED VR")
        XCTAssertEqual(s.lens.make, "Nikon")
        XCTAssertEqual(s.lens.minFocal, 17)
        XCTAssertEqual(s.lens.maxFocal, 55)
        XCTAssertEqual(s.lens.maxApertureAtMinFocal, 2.8, accuracy: 1e-6)
        XCTAssertEqual(s.lens.maxApertureAtMaxFocal, 0, "0/0 reads as unknown")
    }

    /// A merged Canon-style and Nikon-style reference reopen with exactly
    /// the lens the source raw had, name included, in process and after
    /// crossing the decoder service's wire format.
    func testMergedLensReopensIdentical() throws {
        for (name, lensModel, lens) in [("canon", "", Self.canonLens), ("nikon", "", Self.nikonLens),
                                        ("named", "AF-S NIKKOR 24-70mm f/2.8E ED VR", Self.nikonLens)] {
            let source = try Fixtures.summary(lensModel: lensModel, lens: lens)
            let m = try MergeDNGMetadata(summary: source, cameraToXYZ: Fixtures.d750CamXYZ, softwareVersion: "0.9")
            let merged = try reopen(write(m, name: "\(name).dng").url)
            XCTAssertEqual(merged.lens, source.lens, name)
            XCTAssertEqual(merged.lensModel, source.lensModel, name)

            let wire = try JSONDecoder().decode(RawSnapshotMetadata.self, from: JSONEncoder().encode(
                RawSnapshotMetadata(summary: merged, cameraToXYZ: nil, thumbnailError: 0, isMetadataOnly: true,
                                    planeSampleCount: 0))).summary
            XCTAssertEqual(wire.lens, source.lens, name)
            XCTAssertEqual(wire.lensModel, source.lensModel, name)
            XCTAssertEqual(wire.mergeInfo?.lens, m.lens, name)
        }
    }

    /// ImageIO, standing in for other apps, sees a lens name and range
    /// even when the raw had neither an EXIF name nor a maker-notes one.
    func testImageIOSeesTheLensTags() throws {
        for (name, lens, model, spec) in [("canon", Self.canonLens, "EF 50mm f/1.4 USM", [50.0, 50, 0, 0]),
                                          ("nikon", Self.nikonLens, "17-55mm f/2.8", [17, 55, 2.8, 2.8])] {
            let result = try write(metadata(lens: lens), name: "\(name)-imageio.dng")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
            let exif = try XCTUnwrap(props[kCGImagePropertyExifDictionary as String] as? [String: Any])
            XCTAssertEqual(exif[kCGImagePropertyExifLensModel as String] as? String, model, name)
            let exifSpec = try XCTUnwrap(exif[kCGImagePropertyExifLensSpecification as String] as? [Double], name)
            XCTAssertEqual(exifSpec.count, 4, name)
            for (read, written) in zip(exifSpec, spec) { XCTAssertEqual(read, written, accuracy: 1e-6, name) }
            // ImageIO files DNG's LensInfo under the Adobe "aux" EXIF
            // extensions, where Lightroom's XMP keeps it too.
            let aux = try XCTUnwrap(props[kCGImagePropertyExifAuxDictionary as String] as? [String: Any], name)
            let info = try XCTUnwrap(aux[kCGImagePropertyExifAuxLensInfo as String] as? [Double], name)
            XCTAssertEqual(info.count, 4, name)
            for (read, written) in zip(info, spec) { XCTAssertEqual(read, written, accuracy: 1e-6, name) }
        }
    }

    // MARK: - Real raws

    /// The real thing, when the merge test photos are present: a DNG made
    /// with a real reference frame's metadata matches the same lens profile
    /// as that raw. Pixels don't take part in matching, so they are small.
    func testMergedDNGMatchesTheSourceRawsLensProfile() throws {
        let root = TestAssets.url("merge")
        let raws = ["ihrke-tripod-bracket/IMG_7224.CR2", "empa-crete-seashore-1/DSC_0044.NEF"]
            .map { root.appendingPathComponent($0) }
        guard raws.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("TestAssets/merge isn't here (it isn't in CI)")
        }
        let gpu = try HDRTestSupport.gpu()
        for raw in raws {
            let file = try RawFile(path: raw.path)
            let sourceProfile = try ImageSession(file: file, gpu: gpu).lensCorrection?.profileName
            XCTAssertNotNil(sourceProfile, raw.lastPathComponent)

            let m = try MergeDNGMetadata(summary: file.summary, cameraToXYZ: file.cameraToXYZMatrixRaw,
                                         softwareVersion: "0.9")
            let merged = try RawFile(path: write(m, name: raw.lastPathComponent + ".dng").url.path)
            XCTAssertEqual(merged.summary.sourceKind, .linearRGB)
            let mergedProfile = try ImageSession(file: merged, gpu: gpu).lensCorrection?.profileName
            XCTAssertEqual(mergedProfile, sourceProfile, raw.lastPathComponent)
        }
    }
}
