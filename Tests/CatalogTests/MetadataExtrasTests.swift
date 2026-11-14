import XCTest
@testable import Catalog

/// The metadata group: other applications' sidecars, the More descriptive
/// fields, EXIF extras, metadata snapshots with their undo, smart
/// collection fields, and the naming tokens with their modifiers.
@MainActor
final class MetadataExtrasTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUp() async throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-metadata-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        ForeignSidecar.enabledOverrideForTesting = true
    }

    override func tearDown() async throws {
        ForeignSidecar.enabledOverrideForTesting = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private func record(_ name: String = "DSC_0042.NEF") -> ImageRecord {
        ImageRecord(id: 1, relPath: name, preservedName: nil, size: 1, mtime: 1_700_000_000_000,
                    xxhash: Data(count: 8), captureTime: 1_789_321_260, camera: "Nikon D750",
                    lens: "24-70mm f/2.8", lensId: nil, iso: 400, shutter: 0.004, aperture: 2.8, focal: 50,
                    width: 6016, height: 4016, orientation: nil, rating: 3, label: "Red", flag: 0,
                    sidecarMtime: nil, thumbKey: nil)
    }

    private func name(_ template: String, _ record: ImageRecord, keywords: [String] = []) -> String {
        var context = ExportNaming.Context(index: 0, catalogName: "Shoot")
        context.keywords = keywords
        return ExportNaming.fileName(template: template, record: record, context: context,
                                     timeZone: TimeZone(identifier: "UTC")!)
    }

    private static let darktableSidecar = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
            xmlns:darktable="http://darktable.sf.net/"
            xmp:Rating="4">
           <darktable:colorlabels><rdf:Seq><rdf:li>2</rdf:li><rdf:li>0</rdf:li></rdf:Seq></darktable:colorlabels>
           <dc:subject><rdf:Bag><rdf:li>Paris</rdf:li><rdf:li>street</rdf:li></rdf:Bag></dc:subject>
           <lr:hierarchicalSubject><rdf:Bag><rdf:li>Places|France|Paris</rdf:li></rdf:Bag></lr:hierarchicalSubject>
           <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Rue at night</rdf:li></rdf:Alt></dc:title>
           <darktable:history><rdf:Seq><rdf:li darktable:operation="exposure"/></rdf:Seq></darktable:history>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """

    private static let lightroomSidecar = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
            xmlns:xmp="http://ns.adobe.com/xap/1.0/"
            xmlns:dc="http://purl.org/dc/elements/1.1/"
            xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
            xmlns:Iptc4xmpCore="http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
            xmp:Rating="-1" xmp:Label="Blue" photoshop:City="Oslo" photoshop:Headline="Fjord">
           <dc:creator><rdf:Seq><rdf:li>Ann Smith</rdf:li></rdf:Seq></dc:creator>
           <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">© Ann Smith</rdf:li></rdf:Alt></dc:rights>
           <Iptc4xmpCore:CreatorContactInfo Iptc4xmpCore:CiEmailWork="ann@example.com"
             Iptc4xmpCore:CiUrlWork="https://example.com"/>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """

    // MARK: - Other applications' sidecars

    func testForeignSidecarsParseDarktableAndLightroom() throws {
        let dt = folder.appendingPathComponent("A.NEF.xmp")
        try Self.darktableSidecar.write(to: dt, atomically: true, encoding: .utf8)
        let darktable = try ForeignSidecar.read(from: dt)
        XCTAssertEqual(darktable.rating, 4)
        XCTAssertFalse(darktable.rejected)
        XCTAssertEqual(darktable.label, "Green", "darktable's first colour label, 2 is green")
        XCTAssertEqual(darktable.keywords, ["Places|France|Paris", "street"])
        XCTAssertEqual(darktable.descriptive[.title], "Rue at night")

        let lr = folder.appendingPathComponent("B.xmp")
        try Self.lightroomSidecar.write(to: lr, atomically: true, encoding: .utf8)
        let lightroom = try ForeignSidecar.read(from: lr)
        XCTAssertEqual(lightroom.rating, 0)
        XCTAssertTrue(lightroom.rejected, "Rating -1 is a reject")
        XCTAssertEqual(lightroom.label, "Blue")
        XCTAssertEqual(lightroom.descriptive[.creator], "Ann Smith")
        XCTAssertEqual(lightroom.descriptive[.copyright], "© Ann Smith")
        XCTAssertEqual(lightroom.descriptive[.city], "Oslo")
        XCTAssertEqual(lightroom.descriptive[.headline], "Fjord")
        XCTAssertEqual(lightroom.descriptive[.creatorEmail], "ann@example.com")
        XCTAssertEqual(lightroom.descriptive[.creatorURL], "https://example.com")

        XCTAssertEqual(ForeignSidecar.candidates(for: folder.appendingPathComponent("A.NEF")).map(\.lastPathComponent),
                       ["A.NEF.xmp", "A.xmp"])
    }

    func testFillOnlyFillsWhatIsEmpty() {
        let foreign = ForeignMetadata(rating: 4, rejected: true, label: "Green", keywords: ["b", "a"],
                                      descriptive: [.title: "Theirs", .city: "Oslo"])
        var empty = MetadataSnapshot()
        foreign.fill(&empty)
        XCTAssertEqual(empty, MetadataSnapshot(rating: 4, flag: -1, label: "Green", keywords: ["a", "b"],
                                               descriptive: [.title: "Theirs", .city: "Oslo"]))
        var mine = MetadataSnapshot(rating: 2, flag: 1, label: "Red", keywords: ["mine"], descriptive: [.title: "Mine"])
        foreign.fill(&mine)
        XCTAssertEqual(mine, MetadataSnapshot(rating: 2, flag: 1, label: "Red", keywords: ["mine"],
                                              descriptive: [.title: "Mine", .city: "Oslo"]))
    }

    func testReconcileReadsForeignSidecarsForNewPhotosOnlyAndNeverWritesThem() async throws {
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
        try TestAssets.copyD750(to: folder.appendingPathComponent("C.NEF"), variant: 2)
        let dt = folder.appendingPathComponent("A.NEF.xmp"), lr = folder.appendingPathComponent("B.xmp")
        try Self.darktableSidecar.write(to: dt, atomically: true, encoding: .utf8)
        try Self.lightroomSidecar.write(to: lr, atomically: true, encoding: .utf8)
        let before = try [Data(contentsOf: dt), Data(contentsOf: lr)]

        let catalog = try Catalog.open(at: folder)
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.foreignSidecarsRead, 2)
        let a = try await catalog.image(forRelPath: "A.NEF")!
        XCTAssertEqual(a.rating, 4)
        XCTAssertEqual(a.label, "Green")
        XCTAssertEqual(a.title, "Rue at night")
        let keywords = try await catalog.keywords(forImageID: a.id!)
        XCTAssertEqual(Set(keywords), ["Places|France|Paris", "street"])
        let b = try await catalog.image(forRelPath: "B.NEF")!
        XCTAssertEqual(b.flag, ImageFlag.rejected.rawValue)
        XCTAssertEqual(b.city, "Oslo")
        XCTAssertEqual(b.creatorEmail, "ann@example.com")
        // Latent's own sidecar now holds it, so a rebuilt database keeps it.
        let own = try XMPSidecar.read(from: await catalog.sidecarURL(forRelPath: "B.NEF"))
        XCTAssertEqual(own.more[.city], "Oslo")
        XCTAssertEqual(own.flag, -1)
        XCTAssertEqual(try [Data(contentsOf: dt), Data(contentsOf: lr)], before, "other apps' files are never written")
        let c = try await catalog.image(forRelPath: "C.NEF")!
        XCTAssertEqual(c.rating, 0)

        // A later change to their file isn't applied: only new photos read them.
        try Self.darktableSidecar.replacingOccurrences(of: "xmp:Rating=\"4\"", with: "xmp:Rating=\"1\"")
            .write(to: dt, atomically: true, encoding: .utf8)
        _ = try await catalog.reconcile()
        let again = try await catalog.image(forRelPath: "A.NEF")!
        XCTAssertEqual(again.rating, 4)
    }

    func testReconcileLeavesForeignSidecarsAloneWhenSwitchedOff() async throws {
        ForeignSidecar.enabledOverrideForTesting = false
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        try Self.darktableSidecar.write(to: folder.appendingPathComponent("A.NEF.xmp"), atomically: true, encoding: .utf8)
        let catalog = try Catalog.open(at: folder)
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.foreignSidecarsRead, 0)
        let a = try await catalog.image(forRelPath: "A.NEF")!
        XCTAssertEqual(a.rating, 0)
        XCTAssertNil(a.title)
    }

    func testImportCommandFillsEmptyFieldsAsOneUndoStep() async throws {
        ForeignSidecar.enabledOverrideForTesting = false
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
        let manager = UndoManager()
        let library = Library()
        library.undoManager = manager
        try await library.open(folder: folder)
        let catalog = library.catalog
        let a = library.images.first { $0.fileName == "A.NEF" }!.id!
        try await library.setDescriptive(.title, to: "Mine", forImageIDs: [a], in: catalog)
        try Self.darktableSidecar.write(to: folder.appendingPathComponent("A.NEF.xmp"), atomically: true, encoding: .utf8)
        try Self.lightroomSidecar.write(to: folder.appendingPathComponent("B.xmp"), atomically: true, encoding: .utf8)

        let changed = try await library.importForeignSidecars(for: library.images)
        XCTAssertEqual(changed, 2)
        XCTAssertEqual(manager.undoActionName, "Import from Other Apps’ Sidecars (2 Images)")
        var rowA = library.images.first { $0.fileName == "A.NEF" }!
        XCTAssertEqual(rowA.title, "Mine", "what Latent has is kept")
        XCTAssertEqual(rowA.rating, 4)
        XCTAssertEqual(library.keywordsByImage[a], ["Places|France|Paris", "street"])

        manager.undo()
        await library.waitForPendingWork()
        rowA = library.images.first { $0.fileName == "A.NEF" }!
        XCTAssertEqual(rowA.rating, 0)
        XCTAssertEqual(rowA.title, "Mine")
        XCTAssertNil(library.images.first { $0.fileName == "B.NEF" }!.city)
        let keywords = try await catalog!.keywords(forImageID: a)
        XCTAssertEqual(keywords, [])
        manager.redo()
        await library.waitForPendingWork()
        XCTAssertEqual(library.images.first { $0.fileName == "B.NEF" }!.city, "Oslo")
    }

    // MARK: - More descriptive fields

    func testMoreFieldsRoundTripThroughTheSidecarAndAreAbsentWhenEmpty() throws {
        var fields = XMPSidecar.Fields(rating: 2, sourceHash: "xxh64:0000000000000001")
        let url = folder.appendingPathComponent("plain.xmp")
        try XMPSidecar.write(fields, to: url)
        let plain = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(plain.contains("photoshop"), "no More fields, no new namespaces")
        XCTAssertFalse(plain.contains("Iptc4xmpCore"))

        for (i, field) in DescriptiveField.more.enumerated() {
            fields.more[field] = field.isMultiline ? "Line \(i)\nnext & <more>" : "Value \(i) & <more>"
        }
        try XMPSidecar.write(fields, to: url)
        let back = try XMPSidecar.read(from: url)
        XCTAssertEqual(back.more, fields.more)
        XCTAssertEqual(back.rating, 2)
        let xml = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(xml.contains("<photoshop:Headline>Value 0 &amp; &lt;more&gt;</photoshop:Headline>"))
        XCTAssertTrue(xml.contains("<Iptc4xmpCore:CreatorContactInfo rdf:parseType=\"Resource\">"))
    }

    func testMoreFieldsLiveOnTheRowAndSurviveARebuild() async throws {
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        let library = Library()
        library.undoManager = UndoManager()
        try await library.open(folder: folder)
        let id = library.images[0].id!
        try await library.setDescriptive([.city: " Oslo ", .instructions: "No reuse\nwithout credit", .title: "T"],
                                         forImageIDs: [id], in: library.catalog)
        XCTAssertEqual(library.undoManager?.undoActionName, "Apply Metadata Preset")
        let row = library.images[0]
        XCTAssertEqual(row.city, "Oslo")
        XCTAssertEqual(row.instructions, "No reuse\nwithout credit")
        XCTAssertEqual(row.title, "T")
        XCTAssertEqual(MetadataSnapshot(row: row, keywords: []).descriptive.count, 3)

        library.undoManager?.undo()
        await library.waitForPendingWork()
        XCTAssertNil(library.images[0].city)
        XCTAssertNil(library.images[0].title, "the whole preset is one step")

        // The sidecar is the truth: a fresh row takes them back from it.
        library.undoManager?.redo()
        await library.waitForPendingWork()
        let sidecar = try XMPSidecar.read(from: await library.catalog!.sidecarURL(forRelPath: "A.NEF"))
        XCTAssertEqual(sidecar.more[.city], "Oslo")
        XCTAssertEqual(sidecar.title, "T")
    }

    func testExistingValuesAreCountedOncePerPhoto() async throws {
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
        let library = Library()
        try await library.open(folder: folder)
        let ids = library.images.compactMap(\.id)
        try await library.setDescriptive(.creator, to: "Ann", forImageIDs: ids, in: library.catalog)
        try await library.setDescriptive(.city, to: "Oslo", forImageIDs: [ids[0]], in: library.catalog)
        let values = library.existingDescriptiveValues()
        XCTAssertEqual(values[.creator], ["Ann"])
        XCTAssertEqual(values[.city], ["Oslo"])
        XCTAssertNil(values[.title])
    }

    func testCopyMetadataToExportsGivesTheOriginalsValues() async throws {
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        let library = Library()
        try await library.open(folder: folder)
        let source = library.images[0].id!
        library.setSelection([source], primary: source)
        try await library.setDescriptive([.title: "Dusk", .city: "Oslo"], forImageIDs: [source], in: library.catalog)
        try await library.addKeywords(["harbour"])
        try await library.setLabel("Red")
        try TestAssets.copyD750(to: folder.appendingPathComponent("A-export.NEF"), variant: 3)
        let report = try await library.addExportedFiles([
            Library.ExportedFile(url: folder.appendingPathComponent("A-export.NEF"), sourceID: source,
                                 placement: .unstacked, copiesMetadata: true)])
        XCTAssertEqual(report.added, 1)
        try await library.copyMetadata(toExports: [(folder.appendingPathComponent("A-export.NEF"), source)])
        let export = library.images.first { $0.fileName == "A-export.NEF" }!
        XCTAssertEqual(export.title, "Dusk")
        XCTAssertEqual(export.city, "Oslo")
        XCTAssertEqual(export.label, "Red")
        XCTAssertEqual(library.keywordsByImage[export.id!], ["harbour"])
    }

    // MARK: - EXIF extras

    func testExifExtrasParseFromImageIOProperties() {
        let extras = ExifExtras.parse([
            "{Exif}": ["Flash": 16, "ExposureBiasValue": -0.6666, "MeteringMode": 5, "WhiteBalance": 1],
            "{GPS}": ["Latitude": 51.5, "LatitudeRef": "N", "Longitude": 0.14, "LongitudeRef": "W",
                      "Altitude": 12.0, "AltitudeRef": 1],
        ])
        XCTAssertEqual(extras.flashFired, false, "16 is 'did not fire, compulsory'")
        XCTAssertEqual(extras.exposureBias, -0.67)
        XCTAssertEqual(extras.meteringMode, 5)
        XCTAssertEqual(extras.whiteBalanceMode, 1)
        XCTAssertEqual(extras.gpsLatitude, 51.5)
        XCTAssertEqual(extras.gpsLongitude, -0.14)
        XCTAssertEqual(extras.gpsAltitude, -12)
        XCTAssertEqual(ExifExtras.parse(["{Exif}": ["Flash": 1]]).flashFired, true)
        XCTAssertEqual(ExifExtras.parse([:]), ExifExtras())
        XCTAssertNil(ExifExtras.parse(["{GPS}": ["Latitude": 200.0, "Longitude": 1.0]]).gpsLatitude)
    }

    func testExtrasAreReadAtCatalogueAndRowsWithoutThemAreBackfilled() async throws {
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        var row = try await catalog.image(forRelPath: "A.NEF")!
        XCTAssertEqual(row.exifExtrasVersion, ExifExtras.version)
        // An older row, as the migration leaves it, is filled in next pass.
        try await catalog.dbQueue.write { db in
            try db.execute(sql: "UPDATE images SET exif_extras_version = NULL, metering_mode = NULL")
        }
        _ = try await catalog.reconcile()
        row = try await catalog.image(forRelPath: "A.NEF")!
        XCTAssertEqual(row.exifExtrasVersion, ExifExtras.version)
    }

    func testExtraRowsShowVariousWhenTheSelectionDiffers() {
        var a = record(), b = record()
        a.exposureBias = 0.7; b.exposureBias = -1
        a.gpsLatitude = 51.5; a.gpsLongitude = -0.14
        b.gpsLatitude = 51.5; b.gpsLongitude = -0.14
        a.flashFired = true
        XCTAssertEqual(a.extraMetadataRows.map(\.value), ["+0.7 EV", "Fired", "51.50000° N, 0.14000° W"])
        let rows = ImageRecord.extraMetadataRows(for: [a, b])
        XCTAssertEqual(rows.map(\.label), ["Exposure bias", "Flash", "GPS"])
        XCTAssertEqual(rows.map(\.value), ["Various", "Various", "51.50000° N, 0.14000° W"])
        XCTAssertEqual(MetadataFormat.coordinatesForCopying(latitude: 51.5, longitude: -0.14), "51.500000, -0.140000")
        XCTAssertEqual(MetadataFormat.exposureBias(-1.33), "−1.3 EV")
        XCTAssertEqual(MetadataFormat.meteringMode(3), "Spot")
        XCTAssertEqual(MetadataRow.hidden(from: MetadataRow.stored(["GPS", "ISO"])), ["GPS", "ISO"])
    }

    func testSmartCollectionFieldsForTheExtras() {
        var r = record()
        r.exposureBias = -0.7
        r.flashFired = true
        XCTAssertTrue(SmartCriterion(.exposureBias, .atMost, "0").matches(r, isEdited: false, keywords: []))
        XCTAssertFalse(SmartCriterion(.exposureBias, .atLeast, "0").matches(r, isEdited: false, keywords: []))
        XCTAssertTrue(SmartCriterion(.flashFired, .is, "true").matches(r, isEdited: false, keywords: []))
        XCTAssertFalse(SmartCriterion(.hasGPS, .is, "true").matches(r, isEdited: false, keywords: []))
        XCTAssertTrue(SmartCriterion(.hasGPS, .isNot, "true").matches(r, isEdited: false, keywords: []))
        r.gpsLatitude = 1; r.gpsLongitude = 2
        XCTAssertTrue(SmartCriterion(.hasGPS, .is, "true").matches(r, isEdited: false, keywords: []))
        let old = record()
        XCTAssertTrue(SmartCriterion.Field.hasGPS.dependsOnChange(from: old, to: r))
        // Rules saved with the new fields read back.
        let rules = SmartCollectionRules(criteria: [SmartCriterion(field: .flashFired)])
        XCTAssertEqual(SmartCollectionRules(json: rules.json), rules)
    }

    // MARK: - Naming tokens

    func testEachNewToken() {
        var r = record("Day 2/DSC_0042.NEF")
        r.exposureBias = 0.7
        r.title = "Harbour"; r.caption = "Boats"; r.creator = "Ann"; r.copyright = "© Ann"
        r.headline = "Dusk"; r.city = "Oslo"; r.country = "Norway"
        let expected: [ExportNaming.Field: String] = [
            .lens: "24-70mm f_2.8", .maker: "Nikon", .model: "D750", .iso: "400", .shutter: "1-250",
            .aperture: "f2.8", .focal: "50mm", .bias: "+0.7", .width: "6016", .height: "4016", .label: "Red",
            .stars: "★★★", .title: "Harbour", .caption: "Boats", .creator: "Ann", .copyright: "© Ann",
            .headline: "Dusk", .city: "Oslo", .country: "Norway", .keywords: "Paris_boats", .ext: "NEF",
            .version: "0", .original: "DSC_0042",
        ]
        XCTAssertEqual(Set(expected.keys), Set(ExportNaming.Field.allCases), "every token is tested")
        for (field, value) in expected {
            XCTAssertEqual(name("{\(field.rawValue)}", r, keywords: ["boats", "Places|France|Paris"]), value, field.rawValue)
        }
        XCTAssertEqual(ExportNaming.unknownTokens(in: ExportNaming.tokens.map(\.token).joined()), [])

        // A virtual copy's number, a preserved name, a long exposure.
        var copy = record(VirtualCopy.relPath(master: "DSC_0042.NEF", key: .init(number: 2, token: "1a2b3c4d")))
        copy.preservedName = "IMG_1.CR2"
        copy.shutter = 2.5
        copy.exposureBias = 0
        XCTAssertEqual(name("{version}-{original}-{shutter}-{bias}-{ext}", copy), "2-IMG_1-2.5s-0-NEF")
        // Missing values come out empty.
        var bare = record()
        bare.lens = nil; bare.iso = nil; bare.label = nil
        XCTAssertEqual(name("a{lens}{iso}{label}{city}{bias}b", bare), "ab")
    }

    func testModifiers() {
        var r = record()
        r.title = "harbour at dusk"
        XCTAssertEqual(name("{title:upper}", r), "HARBOUR AT DUSK")
        XCTAssertEqual(name("{title:title}", r), "Harbour At Dusk")
        XCTAssertEqual(name("{camera:lower}", r), "nikond750")
        XCTAssertEqual(name("{name:1-3}", r), "DSC")
        XCTAssertEqual(name("{name:5-100}", r), "0042", "a range past the end stops at the end")
        XCTAssertEqual(name("{title/ /_}", r), "harbour_at_dusk")
        XCTAssertEqual(name("{title/ /}", r), "harbouratdusk", "replace with nothing")
        XCTAssertEqual(name("{city|nowhere}", r), "nowhere")
        XCTAssertEqual(name("{title|untitled}", r), "harbour at dusk")
        XCTAssertEqual(name("{title:upper/ /-|x}", r), "HARBOUR-AT-DUSK", "replace, then case")
        XCTAssertEqual(name("{city:upper|none}", r), "none")
        XCTAssertEqual(name("{date|x}", r), "2026-09-13", "a date is never empty")
        // A date's own format still owns its colon, slashes and all.
        XCTAssertEqual(name("{date:yyyy/MM}", r), "2026_09")
        XCTAssertEqual(ExportNaming.parse("{name}").tokens, [.name], "plain tokens parse as before")

        let unknown = ExportNaming.unknownTokens(in: "{title:shout}{name:3-1}{name:0-2}{name/x}{name//y}{nmae|x}{title:upper}")
        XCTAssertEqual(unknown, ["{title:shout}", "{name:3-1}", "{name:0-2}", "{name/x}", "{name//y}", "{nmae|x}"])
    }

    func testTextKeepsWhatAFileNameCant() {
        var r = record()
        r.title = "Dusk"
        let context = ExportNaming.Context(index: 0)
        XCTAssertEqual(ExportNaming.text(template: "{lens} · {title:upper}", record: r, context: context),
                       "24-70mm f/2.8 · DUSK")
        XCTAssertEqual(ExportNaming.text(template: "", record: r, context: context), "")
    }

    func testRenameTemplateKnowsTheNewTokensAndKeepsTitle() {
        var r = record()
        r.title = "Dusk"
        let context = ExportNaming.Context(index: 0)
        let result = RenameTemplate.fileName(template: "{title}-{iso}-{text}", customText: "Oslo", record: r,
                                             context: context)
        XCTAssertEqual(try result.get(), "Dusk-400-Oslo.NEF")
        XCTAssertEqual(RenameTemplate.unknownTokens(in: "{title:upper}{lens}{text}"), [])
        XCTAssertFalse(RenameTemplate.moreTokens.contains { $0.token == "{title}" })
    }
}
