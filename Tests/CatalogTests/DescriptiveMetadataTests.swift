import XCTest
@testable import Catalog

/// Colour labels and the descriptive fields (title, caption, creator,
/// copyright): the values themselves, the sidecar's Dublin Core, the
/// catalog row and its migration, the filter, and the Library's changes
/// with undo.
@MainActor
final class DescriptiveMetadataTests: XCTestCase {
    nonisolated(unsafe) var folder: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        folder = fm.temporaryDirectory.appendingPathComponent("latent-descriptive-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try TestAssets.copyD750(to: folder.appendingPathComponent("A.NEF"))
        try TestAssets.copyD750(to: folder.appendingPathComponent("B.NEF"), variant: 1)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    // MARK: - Values

    func testColorLabelsReadAnyLetterCaseAndKeysFollowLightroom() {
        XCTAssertEqual(ColorLabel(xmpLabel: "Red"), .red)
        XCTAssertEqual(ColorLabel(xmpLabel: " purple "), .purple)
        XCTAssertNil(ColorLabel(xmpLabel: "Approved"))
        XCTAssertNil(ColorLabel(xmpLabel: nil))
        XCTAssertEqual((6...9).map(ColorLabel.forKey), [.red, .yellow, .green, .blue])
        XCTAssertNil(ColorLabel.forKey(5))
        // Choosing the label a photo has takes it off; any other sets it.
        XCTAssertEqual(ColorLabel.label(afterChoosing: .red, current: nil), "Red")
        XCTAssertNil(ColorLabel.label(afterChoosing: .red, current: "red"))
        XCTAssertEqual(ColorLabel.label(afterChoosing: .blue, current: "Red"), "Blue")
        XCTAssertEqual(ColorLabel.label(afterChoosing: .green, current: "Approved"), "Green")
        XCTAssertNil(ColorLabel.label(afterChoosing: nil, current: "Red"))
    }

    func testLabelFilterMatchesAnyChosenLabel() {
        var record = ImageRecord(relPath: "A.NEF", size: 1, mtime: 0, xxhash: Data(count: 8), rating: 0, flag: 0)
        var filter = LibraryFilter()
        XCTAssertFalse(filter.isActive)
        filter.labels = [.color(.red), .none]
        XCTAssertTrue(filter.isActive)
        XCTAssertTrue(filter.matches(record, isEdited: false, keywords: []), "no label passes None")
        record.label = "Red"
        XCTAssertTrue(filter.matches(record, isEdited: false, keywords: []))
        record.label = "Blue"
        XCTAssertFalse(filter.matches(record, isEdited: false, keywords: []))
        record.label = "Approved"
        XCTAssertFalse(filter.matches(record, isEdited: false, keywords: []))
        filter.labels = [.custom]
        XCTAssertTrue(filter.matches(record, isEdited: false, keywords: []))
    }

    func testTextSearchFindsTitlesAndCaptions() {
        var record = ImageRecord(relPath: "DSC_1.NEF", size: 1, mtime: 0, xxhash: Data(count: 8), rating: 0, flag: 0)
        record.title = "Harbour at dusk"
        record.caption = "Fishing boats coming in"
        var filter = LibraryFilter()
        for needle in ["dsc_1", "HARBOUR", "boats"] {
            filter.text = needle
            XCTAssertTrue(filter.matches(record, isEdited: false, keywords: []), needle)
        }
        filter.text = "mountain"
        XCTAssertFalse(filter.matches(record, isEdited: false, keywords: []))
    }

    func testTypedTextIsCleanedForTheSidecar() {
        XCTAssertNil(DescriptiveField.normalized("   "))
        XCTAssertNil(DescriptiveField.normalized(nil))
        XCTAssertEqual(DescriptiveField.normalized("  Dusk \u{0001}"), "Dusk")
        XCTAssertEqual(DescriptiveField.normalized("a\nb\tc"), "a b c", "one-line fields have no breaks")
        XCTAssertEqual(DescriptiveField.normalized("a\r\nb", multiline: true), "a\nb")
        var record = ImageRecord(relPath: "A.NEF", size: 1, mtime: 0, xxhash: Data(count: 8), rating: 0, flag: 0)
        DescriptiveField.caption.set(" line one\nline two ", on: &record)
        XCTAssertEqual(record.caption, "line one\nline two")
        XCTAssertEqual(DescriptiveField.title.shared(by: []), .same(nil))
        var other = record
        other.title = "X"
        XCTAssertEqual(DescriptiveField.title.shared(by: [record, other]), .mixed)
        XCTAssertEqual(DescriptiveField.caption.shared(by: [record, other]), .same("line one\nline two"))
    }

    // MARK: - Sidecar

    func testDescriptiveFieldsRoundTripThroughTheSidecar() throws {
        var fields = XMPSidecar.Fields(rating: 2, label: "Purple", sourceHash: "xxh64:0011223344556677")
        fields.title = "Rock & \"roll\" <live>"
        fields.caption = "Line one\nLine two ]]> café"
        fields.creator = "Ann Smith; Bo Lee"
        fields.copyright = "© 2026 Ann Smith"
        let url = folder.appendingPathComponent("round.xmp")
        try XMPSidecar.write(fields, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("<dc:creator><rdf:Seq><rdf:li>Ann Smith</rdf:li><rdf:li>Bo Lee</rdf:li></rdf:Seq></dc:creator>"), text)
        XCTAssertTrue(text.contains(#"<dc:title><rdf:Alt><rdf:li xml:lang="x-default">"#), text)
        let read = try XMPSidecar.read(from: url)
        XCTAssertEqual(read, fields)
    }

    /// A sidecar with none of them is written exactly as before they
    /// existed, so nothing changes for photos nobody has captioned.
    func testNoDescriptiveFieldsLeavesTheSidecarAsItWas() throws {
        let fields = XMPSidecar.Fields(rating: 1, keywords: ["a"], sourceHash: "xxh64:0011223344556677")
        XCTAssertEqual(XMPSidecar.descriptiveElements(fields), "")
        let url = folder.appendingPathComponent("plain.xmp")
        try XMPSidecar.write(fields, to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        for element in ["dc:title", "dc:description", "dc:creator", "dc:rights"] {
            XCTAssertFalse(text.contains(element), element)
        }
        XCTAssertEqual(try XMPSidecar.read(from: url), fields)
    }

    /// What Lightroom writes: several languages, creators in a Seq.
    func testReadsLightroomStyleDublinCore() throws {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"
             xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:Label="Yellow">
           <dc:title><rdf:Alt>
             <rdf:li xml:lang="de">Hafen</rdf:li>
             <rdf:li xml:lang="x-default">Harbour</rdf:li>
           </rdf:Alt></dc:title>
           <dc:description><rdf:Alt><rdf:li xml:lang="x-default">Boats</rdf:li></rdf:Alt></dc:description>
           <dc:creator><rdf:Seq><rdf:li>Ann</rdf:li><rdf:li>Bo</rdf:li></rdf:Seq></dc:creator>
           <dc:rights><rdf:Alt><rdf:li xml:lang="x-default">© Ann</rdf:li></rdf:Alt></dc:rights>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let fields = try XMPSidecar.read(xml: xml)
        XCTAssertEqual(fields.label, "Yellow")
        XCTAssertEqual(fields.title, "Harbour")
        XCTAssertEqual(fields.caption, "Boats")
        XCTAssertEqual(fields.creator, "Ann; Bo")
        XCTAssertEqual(fields.copyright, "© Ann")
    }

    // MARK: - Catalog

    /// The migration adds the columns to a catalog made before it; the
    /// values go to the row and the sidecar, and a database rebuilt from
    /// the sidecars alone gets them back.
    func testCatalogStoresFieldsAndARebuiltDatabaseReadsThemBack() async throws {
        do {
            let catalog = try Catalog.open(at: folder)
            _ = try await catalog.reconcile()
            let found = try await catalog.image(forRelPath: "A.NEF")
            let a = try XCTUnwrap(found?.id)
            let before = try await catalog.exchangeLabel("Green", forImageID: a)
            XCTAssertNil(before?.label)
            try await catalog.exchangeDescriptive(.title, "  Harbour ", forImageID: a)
            try await catalog.exchangeDescriptive(.caption, "Boats\nat dusk", forImageID: a)
            try await catalog.exchangeDescriptive(.creator, "Ann", forImageID: a)
            let previous = try await catalog.exchangeDescriptive(.copyright, "© Ann", forImageID: a)
            XCTAssertEqual(previous?.title, "Harbour")
            XCTAssertNil(previous?.copyright)
            let sidecar = try XMPSidecar.read(from: await catalog.sidecarURL(forRelPath: "A.NEF"))
            XCTAssertEqual(sidecar.title, "Harbour")
            XCTAssertEqual(sidecar.caption, "Boats\nat dusk")
            XCTAssertEqual(sidecar.label, "Green")
        }
        // The sidecars are the truth: a fresh database fills from them.
        try FileManager.default.removeItem(at: folder.appendingPathComponent("_latent/catalog.sqlite"))
        let rebuilt = try Catalog.open(at: folder)
        _ = try await rebuilt.reconcile()
        let foundA = try await rebuilt.image(forRelPath: "A.NEF")
        let a = try XCTUnwrap(foundA)
        XCTAssertEqual(a.label, "Green")
        XCTAssertEqual(a.title, "Harbour")
        XCTAssertEqual(a.caption, "Boats\nat dusk")
        XCTAssertEqual(a.creator, "Ann")
        XCTAssertEqual(a.copyright, "© Ann")
        let foundB = try await rebuilt.image(forRelPath: "B.NEF")
        let b = try XCTUnwrap(foundB)
        XCTAssertNil(b.title)
        XCTAssertNil(b.label)
    }

    /// Setting what is already there writes nothing, not even the sidecar.
    func testUnchangedValueLeavesTheSidecarAlone() async throws {
        let catalog = try Catalog.open(at: folder)
        _ = try await catalog.reconcile()
        let found = try await catalog.image(forRelPath: "A.NEF")
        let a = try XCTUnwrap(found?.id)
        try await catalog.exchangeDescriptive(.title, "T", forImageID: a)
        let url = await catalog.sidecarURL(forRelPath: "A.NEF")
        let stamp = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: url.path)
        try await catalog.exchangeDescriptive(.title, "T ", forImageID: a)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertNotNil(stamp)
        XCTAssertEqual(after, Date(timeIntervalSince1970: 1000))
        let missing = try await catalog.exchangeDescriptive(.title, "x", forImageID: 9999)
        XCTAssertNil(missing, "no such image")
    }

    // MARK: - Library and undo

    private func openLibrary(_ manager: UndoManager) async throws -> Library {
        let library = Library()
        library.undoManager = manager
        try await library.open(folder: folder)
        XCTAssertEqual(library.images.count, 2)
        return library
    }

    private func record(_ library: Library, _ name: String) -> ImageRecord {
        library.images.first { $0.fileName == name }!
    }

    private func undo(_ manager: UndoManager, _ library: Library, redo: Bool = false) async {
        if redo { manager.redo() } else { manager.undo() }
        await library.waitForPendingWork()
    }

    func testLabelKeysToggleByThePrimaryAndUndo() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let (a, b) = (record(library, "A.NEF").id!, record(library, "B.NEF").id!)

        library.setSelection([b], primary: b)
        try await library.chooseLabel(.blue)
        library.setSelection([a, b], primary: a)
        try await library.chooseLabel(.red)
        XCTAssertEqual(record(library, "A.NEF").label, "Red")
        XCTAssertEqual(record(library, "B.NEF").label, "Red")
        XCTAssertEqual(manager.undoActionName, "Label (2 Images)")

        // The primary has red: the key takes it off them all.
        try await library.chooseLabel(.red)
        XCTAssertNil(record(library, "A.NEF").label)
        XCTAssertNil(record(library, "B.NEF").label)

        await undo(manager, library)
        XCTAssertEqual(record(library, "A.NEF").label, "Red")
        await undo(manager, library)
        XCTAssertNil(record(library, "A.NEF").label)
        XCTAssertEqual(record(library, "B.NEF").label, "Blue", "each image gets its own label back")
        let sidecar = try XMPSidecar.read(from: await library.catalog!.sidecarURL(forRelPath: "B.NEF"))
        XCTAssertEqual(sidecar.label, "Blue")
        await undo(manager, library, redo: true)
        XCTAssertEqual(record(library, "B.NEF").label, "Red")
    }

    func testDescriptiveFieldOnSeveralPhotosKeepsTheirOtherFieldsAndUndoes() async throws {
        let manager = UndoManager()
        let library = try await openLibrary(manager)
        let (a, b) = (record(library, "A.NEF").id!, record(library, "B.NEF").id!)
        let catalog = library.catalog

        try await library.setDescriptive(.title, to: "First", forImageIDs: [a], in: catalog)
        try await library.setDescriptive(.title, to: "Second", forImageIDs: [b], in: catalog)
        try await library.setDescriptive(.copyright, to: "© Ann", forImageIDs: [a, b], in: catalog)
        XCTAssertEqual(manager.undoActionName, "Copyright (2 Images)")
        XCTAssertEqual(record(library, "A.NEF").title, "First")
        XCTAssertEqual(record(library, "B.NEF").title, "Second")
        XCTAssertEqual(record(library, "B.NEF").copyright, "© Ann")

        await undo(manager, library)
        XCTAssertNil(record(library, "A.NEF").copyright)
        XCTAssertNil(record(library, "B.NEF").copyright)
        XCTAssertEqual(record(library, "B.NEF").title, "Second")
        await undo(manager, library, redo: true)
        XCTAssertEqual(record(library, "A.NEF").copyright, "© Ann")

        // A catalog that is no longer the open one is never written.
        let other = try Catalog.open(at: folder)
        try await library.setDescriptive(.title, to: "Elsewhere", forImageIDs: [a], in: other)
        XCTAssertEqual(record(library, "A.NEF").title, "First")
    }
}
