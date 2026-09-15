import XCTest
import simd
import PixelEngine
import RawCore
@testable import MergeKit

/// Real photos from TestAssets (not in the repository; skipped when missing
/// or with LATENT_CI_ASSETS_ONLY=1): Harman's 17-frame D750 panorama must
/// lay out in order, and the HDR brackets must be refused as panoramas.
///
/// Set LATENT_PANO_REVIEW to a folder to have the panorama test write a
/// quick stitch there (harman-preview.jpg) for checking by eye.
final class PanoGeometryRealTests: XCTestCase {
    private func photos(_ folder: String) throws -> [URL] {
        try XCTSkipIf(ProcessInfo.processInfo.environment["LATENT_CI_ASSETS_ONLY"] == "1", "CI assets only")
        let directory = AlignTestSupport.assets.appendingPathComponent(folder)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("TestAssets/\(folder) is missing")
        }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { ["nef", "cr2"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func testHarmansPanoramaConnectsAllSeventeenFramesInOrder() throws {
        let urls = try photos("pano")
        XCTAssertEqual(urls.count, 17)
        let gpu = try HDRTestSupport.gpu()
        let prep = PanoramaFramePrep(gpu: gpu)
        // Shuffled on the way in: capture order must put them back.
        let photos = try prep.photos(urls.reversed())
        XCTAssertEqual(photos.map(\.url.lastPathComponent), urls.map(\.lastPathComponent))
        let inputs = try photos.map { try prep.input(for: $0) }
        // The D750's active area is 6032 x 4032; portrait, so upright it is tall.
        XCTAssertEqual([photos[0].metadata.width, photos[0].metadata.height], [4032, 6032])
        XCTAssertEqual(inputs[0].thumbnail.width, 4032 / 8)

        let result = try PanoramaLayoutSolver().solve(inputs)
        let layout = result.layout, report = result.report
        for pair in report.pairs {
            print("pano-real | pair \(pair.first)-\(pair.second) \(pair.method?.rawValue ?? "rejected") "
                  + String(format: "NCC %.3f overlap %.2f", pair.ncc, pair.overlap) + (pair.note.map { " (\($0))" } ?? ""))
        }
        XCTAssertEqual(layout.cameras.map(\.frameIndex), Array(0..<17), "all 17 frames connected")
        let yaws = layout.cameras.map { PanoramaRotation.yawPitchRoll($0.rotationMatrix).yaw }
        for k in 1..<yaws.count {
            XCTAssertGreaterThan(yaws[k], yaws[k - 1] + 3, "frame \(k) turned on from frame \(k - 1)")
        }
        // Handheld, so pitch and roll wander, but only by a few degrees.
        for camera in layout.cameras {
            let a = PanoramaRotation.yawPitchRoll(camera.rotationMatrix)
            XCTAssertLessThan(abs(a.roll), 5)
            XCTAssertLessThan(abs(a.pitch), 20)
        }
        XCTAssertEqual(layout.canvas.projection, .cylindrical)
        XCTAssertLessThan(report.rmsErrorPixels, 16, "correspondences explained to a couple of thumbnail texels")
        XCTAssertEqual(report.focalLengthPixels / report.exifFocalLengthPixels, 1, accuracy: 0.05)
        // The aperture varies by a stop; the gains must make overlaps agree.
        for m in report.exposureMeasurements where m.samples >= 2000 {
            XCTAssertLessThan(abs(m.remainingStops), 0.05, "pair \(m.first)-\(m.second) exposure")
        }
        let crop = layout.autoCropRect
        XCTAssertGreaterThan(crop.width, 0.8 * Double(layout.canvas.width))

        let size = PanoramaOutputSizer.size(fullWidth: layout.canvas.width, fullHeight: layout.canvas.height,
                                            device: gpu.device)
        XCTAssertLessThan(size.scale, 1, "beyond what a Mac can edit at full size")
        XCTAssertLessThanOrEqual(size.width, PanoramaOutputSizer.maxTextureSide(gpu.device))
        print(String(format: "pano-real | canvas %d x %d, %.1f° x %.1f°, focal %.1f px (EXIF %.1f), RMS %.2f px, "
                     + "output %d x %d at %.3f (%@), decode span %d, layout %.2f s",
                     layout.canvas.width, layout.canvas.height, report.widthDegrees, report.heightDegrees,
                     report.focalLengthPixels, report.exifFocalLengthPixels, report.rmsErrorPixels, size.width,
                     size.height, size.scale, size.limit.rawValue, size.decodeSpan, report.totalSeconds))
        for stage in report.stages { print(String(format: "pano-real | stage %@ %.2f s", stage.name, stage.seconds)) }

        if let folder = ProcessInfo.processInfo.environment["LATENT_PANO_REVIEW"] {
            var thumbnails: [Int: PanoramaThumbnail] = [:]
            for camera in layout.cameras { thumbnails[camera.frameIndex] = inputs[camera.frameIndex].thumbnail }
            let image = PanoramaPreview.stitch(layout, thumbnails: thumbnails, longSide: 3000)
            let reference = try RawFile(path: photos[0].url.path, metadataOnly: true)
            let rendered = try PanoramaPreview.render(image, reference: photos[0].summary,
                                                      cameraToXYZ: reference.cameraToXYZMatrixRaw, gpu: gpu)
            try PanoramaPreview.writeJPEG(rendered, to: URL(fileURLWithPath: folder).appendingPathComponent("harman-preview.jpg"))
        }
    }

    /// A prepared full-size frame from the set, reduced for review: upright,
    /// lens-corrected, with coverage.
    func testHarmansFramePreparesUprightWithCoverage() throws {
        let urls = try photos("pano")
        let gpu = try HDRTestSupport.gpu()
        let prep = PanoramaFramePrep(gpu: gpu)
        let photo = try prep.photos(Array(urls.prefix(2)))[0]
        XCTAssertNotNil(photo.lens, "the AF-S 50mm f/1.4G has a Lensfun profile")
        let texture = try prep.prepare(photo, span: 2, multipliers: PanoramaFramePrep.sharedMultipliers([photo]),
                                       storage: .shared)
        XCTAssertEqual([texture.width, texture.height], [4032 / 2, 6032 / 2])
        var halves = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&halves, bytesPerRow: texture.width * 8,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        // Upright: the sky (bright) above the ground (dark).
        func meanGreen(rows: Range<Int>) -> Double {
            var sum = 0.0, count = 0
            for y in rows { for x in stride(from: 0, to: texture.width, by: 4) { sum += Double(halves[4 * (y * texture.width + x) + 1]); count += 1 } }
            return sum / Double(count)
        }
        XCTAssertGreaterThan(meanGreen(rows: 0..<300), 2 * meanGreen(rows: (texture.height - 300)..<texture.height))
        let covered = stride(from: 3, to: halves.count, by: 4).filter { halves[$0] == 1 }.count
        XCTAssertGreaterThan(Double(covered), 0.97 * Double(texture.width * texture.height))

        if let folder = ProcessInfo.processInfo.environment["LATENT_PANO_REVIEW"] {
            let span = 4
            let w = texture.width / span, h = texture.height / span
            var rgba = [Float](repeating: 0, count: w * h * 4)
            for y in 0..<h {
                for x in 0..<w {
                    for c in 0..<4 { rgba[4 * (y * w + x) + c] = Float(halves[4 * (y * span * texture.width + x * span) + c]) }
                }
            }
            let image = PanoramaPreview.Image(width: w, height: h, scale: 1, rgba: rgba)
            let reference = try RawFile(path: photo.url.path, metadataOnly: true)
            let rendered = try PanoramaPreview.render(image, reference: photo.summary,
                                                      cameraToXYZ: reference.cameraToXYZMatrixRaw, gpu: gpu)
            try PanoramaPreview.writeJPEG(rendered, to: URL(fileURLWithPath: folder).appendingPathComponent("prepared-frame.jpg"))
        }
    }

    func testBracketsAreRefusedAsPanoramas() throws {
        let gpu = try HDRTestSupport.gpu()
        let prep = PanoramaFramePrep(gpu: gpu)
        for folder in ["merge/ihrke-tripod-bracket", "merge/empa-market-mires-2"] {
            let urls = try photos(folder)
            let inputs = try prep.photos(urls).map { try prep.input(for: $0) }
            XCTAssertThrowsError(try PanoramaLayoutSolver().solve(inputs), folder) { error in
                guard case PanoramaError.notAPanorama(let reason) = error else { return XCTFail("\(folder): \(error)") }
                print("pano-real | \(folder): \(reason)")
            }
        }
    }
}
