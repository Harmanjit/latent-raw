import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import Catalog
@testable import RawCore

/// JPEG, PNG, TIFF and HEIC in the catalog: indexed by reconcile with
/// their EXIF, given thumbnails, and RAW+JPEG pairs hidden behind their
/// raw and carried with it when it moves, is copied or renamed.
@MainActor
final class RenderedImageCatalogTests: XCTestCase {
    nonisolated(unsafe) var base: URL!
    nonisolated(unsafe) var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("latent-formats-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Shoot", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    /// A small sRGB picture written as `type`, with distinct content per
    /// `seed` so no two files share a hash.
    nonisolated static func writePicture(to url: URL, type: UTType, seed: Int = 0, width: Int = 48, height: Int = 32,
                                         properties: [CFString: Any] = [:]) throws {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8((x * 5 + seed * 37) & 255)
                bytes[i + 1] = UInt8((y * 7 + seed * 11) & 255)
                bytes[i + 2] = UInt8((x + y + seed) & 255)
            }
        }
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                            shouldInterpolate: false, intent: .defaultIntent)!
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func exists(_ relPath: String, in folder: URL? = nil) -> Bool {
        fm.fileExists(atPath: (folder ?? root).appendingPathComponent(relPath).path)
    }

    // MARK: - Pairing rules

    func testPairsAreSameFolderSameNameRawAndJPEG() {
        let pairs = RawJPEGPairs.companions(in: [
            "DSC_0107.NEF", "DSC_0107.JPG",          // a pair
            "Day 2/IMG_1.CR3", "Day 2/img_1.jpeg",   // case doesn't matter
            "IMG_2.ARW", "IMG_2.HIF",                // RAW+HEIF
            "Day 3/IMG_1.JPG",                       // another folder's IMG_1
            "scan.tif", "scan.png",                  // no raw
            "P1.DNG", "P1.NEF", "P1.jpg",            // two raws: the first by path
            "Lonely.JPG",
        ])
        XCTAssertEqual(pairs, [
            "DSC_0107.JPG": "DSC_0107.NEF",
            "Day 2/img_1.jpeg": "Day 2/IMG_1.CR3",
            "IMG_2.HIF": "IMG_2.ARW",
            "P1.jpg": "P1.DNG",
        ])
    }

    func testATIFFOrPNGBesideARawIsNotAPair() {
        XCTAssertTrue(RawJPEGPairs.companions(in: ["A.NEF", "A.tif", "A.png"]).isEmpty,
                      "an edited TIFF or a PNG export is a picture of its own")
    }

    func testCompanionNameFollowsTheRaw() {
        XCTAssertEqual(RawJPEGPairs.companionName(forRawName: "Trip 001.NEF", companion: "DSC_0107.JPG"), "Trip 001.JPG")
        XCTAssertEqual(RawJPEGPairs.companionName(forRawName: "A 2.NEF", companion: "A.heic"), "A 2.heic")
    }

    func testCompanionRequestsFollowWhereTheRawWent() {
        let raw = root.appendingPathComponent("A.NEF"), jpeg = root.appendingPathComponent("A.JPG")
        let archive = base.appendingPathComponent("Archive")
        let completed = [CompletedTransfer(kind: .move, source: raw, destination: archive.appendingPathComponent("A 2.NEF"),
                                           destinationIdentity: nil, preservedNameChanged: false,
                                           previousPreservedName: nil, newPreservedName: nil)]
        let requests = LibraryFileOperations.companionRequests([raw.standardizedFileURL: [jpeg]], following: completed)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.source, jpeg)
        XCTAssertEqual(requests.first?.folder.standardizedFileURL.path, archive.standardizedFileURL.path)
        XCTAssertEqual(requests.first?.name, "A 2.JPG")
        XCTAssertTrue(LibraryFileOperations.companionRequests([:], following: completed).isEmpty)
    }

    // MARK: - Reconcile and thumbnails

    func testReconcileIndexesPicturesWithTheirEXIF() async throws {
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2025:06:01 09:30:00",
                                     kCGImagePropertyExifISOSpeedRatings: [200],
                                     kCGImagePropertyExifFNumber: 8.0]
        let tiff: [CFString: Any] = [kCGImagePropertyTIFFMake: "FUJIFILM", kCGImagePropertyTIFFModel: "X-T5"]
        try Self.writePicture(to: root.appendingPathComponent("Phone.JPG"), type: .jpeg, seed: 1,
                              properties: [kCGImagePropertyExifDictionary: exif, kCGImagePropertyTIFFDictionary: tiff])
        try Self.writePicture(to: root.appendingPathComponent("Scan.tif"), type: .tiff, seed: 2, width: 40, height: 60)
        try Self.writePicture(to: root.appendingPathComponent("Screen.png"), type: .png, seed: 3)
        try Self.writePicture(to: root.appendingPathComponent("Phone.heic"), type: .heic, seed: 4)
        try Data("not a picture".utf8).write(to: root.appendingPathComponent("notes.txt"))

        let catalog = try Catalog.open(at: root)
        let report = try await catalog.reconcile()
        XCTAssertEqual(report.added, 4, "\(report)")
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        let images = try await catalog.allImages()
        let byName = Dictionary(uniqueKeysWithValues: images.map { ($0.relPath, $0) })
        let phone = try XCTUnwrap(byName["Phone.JPG"])
        XCTAssertEqual(phone.camera, "FUJIFILM X-T5")
        XCTAssertEqual(phone.iso, 200)
        XCTAssertEqual(phone.aperture, 8)
        XCTAssertEqual(phone.width, 48)
        XCTAssertNotNil(phone.captureTime)
        let scan = try XCTUnwrap(byName["Scan.tif"])
        XCTAssertEqual(scan.width, 40)
        XCTAssertEqual(scan.height, 60)
        XCTAssertNil(scan.camera)
        XCTAssertNotNil(scan.captureTime, "the file date stands in for a missing capture time")

        _ = try await catalog.generateMissingThumbnails()
        for name in ["Phone.JPG", "Scan.tif", "Screen.png", "Phone.heic"] {
            let thumbnail = await catalog.thumbnailURL(forRelPath: name)
            XCTAssertTrue(fm.fileExists(atPath: thumbnail.path), "thumbnail for \(name)")
        }
        let scanURL = await catalog.thumbnailURL(forRelPath: "Scan.tif")
        let scanThumbnail = try XCTUnwrap(Thumbnailer.load(from: scanURL))
        XCTAssertEqual(scanThumbnail.width, 40)
        XCTAssertEqual(scanThumbnail.height, 60)
    }

    func testThumbnailIsTurnedUprightByItsOrientation() throws {
        let source = root.appendingPathComponent("Turned.jpg")
        try Self.writePicture(to: source, type: .jpeg, width: 60, height: 20,
                              properties: [kCGImagePropertyOrientation: 6])
        let destination = base.appendingPathComponent("t.heic")
        try Thumbnailer.makeFromEmbeddedPreview(rawFileAt: source, to: destination)
        let image = try XCTUnwrap(Thumbnailer.load(from: destination))
        XCTAssertEqual(image.width, 20)
        XCTAssertEqual(image.height, 60)
    }

    // MARK: - RAW+JPEG through the Library

    private func openLibrary() async throws -> (Library, UndoManager) {
        try TestAssets.copyD750(to: root.appendingPathComponent("A.NEF"))
        try Self.writePicture(to: root.appendingPathComponent("A.JPG"), type: .jpeg, seed: 5)
        try Self.writePicture(to: root.appendingPathComponent("Other.JPG"), type: .jpeg, seed: 6)
        let library = Library()
        let undo = UndoManager()
        library.undoManager = undo
        try await library.open(folder: root, defaultSubfolderMode: .included)
        return (library, undo)
    }

    private func record(_ library: Library, _ relPath: String) -> ImageRecord? {
        library.images.first { $0.relPath == relPath }
    }

    private func undoing(_ undo: UndoManager, _ library: Library) async {
        undo.undo()
        await library.waitForPendingWork()
        while library.fileOperations.isBusy || library.hasPendingWork {
            await library.waitForPendingWork()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testThePairedJPEGIsHiddenUntilAskedFor() async throws {
        let (library, _) = try await openLibrary()
        XCTAssertEqual(library.images.count, 3, "all three are catalogued")
        XCTAssertEqual(Set(library.visibleImages.map(\.relPath)), ["A.NEF", "Other.JPG"])
        let raw = try XCTUnwrap(record(library, "A.NEF"))
        XCTAssertEqual(library.companionsTravelling(with: raw).map(\.relPath), ["A.JPG"])
        XCTAssertEqual(library.pairedCompanions[raw.id!]?.map(\.relPath), ["A.JPG"])

        library.showsPairedCompanions = true
        XCTAssertEqual(Set(library.visibleImages.map(\.relPath)), ["A.NEF", "A.JPG", "Other.JPG"])
        XCTAssertTrue(library.companionsTravelling(with: raw).isEmpty, "shown separately, it goes its own way")

        // Selecting it, then hiding it again, deselects it.
        let jpeg = try XCTUnwrap(record(library, "A.JPG"))
        library.setSelection([jpeg.id!, raw.id!], primary: raw.id)
        library.showsPairedCompanions = false
        XCTAssertEqual(library.selectedImageIDs, [raw.id!])
    }

    func testTheJPEGMovesWithItsRawAndComesBackOnUndo() async throws {
        let (library, undo) = try await openLibrary()
        let archive = base.appendingPathComponent("Archive", isDirectory: true)
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        let raw = try XCTUnwrap(record(library, "A.NEF"))

        let report = await library.fileOperations.transfer([raw], to: archive, mode: .move)
        XCTAssertEqual(report.completed.count, 2, report.failureDescription)
        XCTAssertTrue(exists("A.NEF", in: archive))
        XCTAssertTrue(exists("A.JPG", in: archive), "the JPEG went with it")
        XCTAssertFalse(exists("A.JPG"))
        XCTAssertNotNil(record(library, "Other.JPG"), "an unpaired JPEG stays")

        await undoing(undo, library)
        XCTAssertTrue(exists("A.NEF"))
        XCTAssertTrue(exists("A.JPG"))
        XCTAssertFalse(exists("A.JPG", in: archive))
        XCTAssertEqual(Set(library.visibleImages.map(\.relPath)), ["A.NEF", "Other.JPG"])
    }

    func testACopyNumberedOnArrivalKeepsThePair() async throws {
        let (library, undo) = try await openLibrary()
        let raw = try XCTUnwrap(record(library, "A.NEF"))
        let report = await library.fileOperations.transfer([raw], to: root, mode: .copy)
        XCTAssertEqual(report.completed.map { $0.destination.lastPathComponent }.sorted(), ["A 2.JPG", "A 2.NEF"],
                       report.failureDescription)
        XCTAssertTrue(exists("A.JPG"), "a copy leaves the original pair")
        XCTAssertEqual(Set(library.visibleImages.map(\.relPath)), ["A.NEF", "A 2.NEF", "Other.JPG"])
        XCTAssertEqual(undo.undoActionName, "Copy 2 Images")
    }

    func testRenamingTheRawRenamesItsJPEG() async throws {
        let (library, undo) = try await openLibrary()
        let raw = try XCTUnwrap(record(library, "A.NEF"))
        try await library.fileOperations.rename(raw, to: "Sunset.NEF")
        XCTAssertTrue(exists("Sunset.NEF"))
        XCTAssertTrue(exists("Sunset.JPG"))
        XCTAssertFalse(exists("A.JPG"))
        XCTAssertNil(library.lastError)
        XCTAssertEqual(Set(library.visibleImages.map(\.relPath)), ["Sunset.NEF", "Other.JPG"])

        await undoing(undo, library)
        XCTAssertTrue(exists("A.NEF"))
        XCTAssertTrue(exists("A.JPG"))
        XCTAssertFalse(exists("Sunset.JPG"))
    }

    func testShownSeparatelyTheJPEGStaysBehind() async throws {
        let (library, _) = try await openLibrary()
        library.showsPairedCompanions = true
        let raw = try XCTUnwrap(record(library, "A.NEF"))
        try await library.fileOperations.rename(raw, to: "Sunset.NEF")
        XCTAssertTrue(exists("Sunset.NEF"))
        XCTAssertTrue(exists("A.JPG"))
    }
}
