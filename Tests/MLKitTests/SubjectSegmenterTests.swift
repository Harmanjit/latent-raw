import XCTest
import CoreGraphics
import ImageIO
@testable import MLKit
@testable import PixelEngine

/// The portrait the face and subject tests share (TestAssets/portrait,
/// fetched by scripts/fetch_test_assets.sh --portrait). Tests skip when
/// it is missing.
enum PortraitAsset {
    static let name = "portrait/zena_cardman_nasa_portrait.jpg"

    /// The face Vision finds in this file (TestAssets/portrait/NOTES.md),
    /// as a normalised rectangle with the origin top-left.
    static let faceBox = CGRect(x: 0.3856, y: 1 - 0.5853 - 0.2293, width: 0.2866, height: 0.2293)

    /// The portrait, upright, resized so its long edge is `longEdge`.
    static func image(longEdge: Int) throws -> CGImage {
        let url = TestAssets.url(name)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "no portrait in TestAssets/: run scripts/fetch_test_assets.sh --portrait")
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw XCTSkip("the portrait could not be decoded")
        }
        return try XCTUnwrap(SyntheticImage.resized(full, longEdge: longEdge))
    }
}

/// Small pictures made in memory for the model tests.
enum SyntheticImage {
    static func resized(_ image: CGImage, longEdge: Int) -> CGImage? {
        let scale = Double(longEdge) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// An sRGB picture from a per-pixel colour, origin top-left.
    static func make(width: Int, height: Int, pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
            }
        }
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    /// The red channel of every pixel, row-major with the origin top-left.
    static func redBytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 0, to: bytes.count, by: 4).map { bytes[$0] }
    }
}

extension MaskBitmap {
    /// Fraction of pixels above half inside a normalised rectangle (origin top-left).
    func coverage(in rect: CGRect) -> Double {
        let x0 = max(0, Int(rect.minX * CGFloat(width))), x1 = min(width, Int(rect.maxX * CGFloat(width)))
        let y0 = max(0, Int(rect.minY * CGFloat(height))), y1 = min(height, Int(rect.maxY * CGFloat(height)))
        var on = 0, n = 0
        for y in y0..<max(y1, y0 + 1) where y < height {
            for x in x0..<max(x1, x0 + 1) where x < width {
                n += 1
                if data[y * width + x] > 127 { on += 1 }
            }
        }
        return Double(on) / Double(max(n, 1))
    }

    /// Mean value 0…1 inside a normalised rectangle.
    func mean(in rect: CGRect) -> Double {
        let x0 = max(0, Int(rect.minX * CGFloat(width))), x1 = min(width, Int(rect.maxX * CGFloat(width)))
        let y0 = max(0, Int(rect.minY * CGFloat(height))), y1 = min(height, Int(rect.maxY * CGFloat(height)))
        var sum = 0.0, n = 0.0
        for y in y0..<max(y1, y0 + 1) where y < height {
            for x in x0..<max(x1, x0 + 1) where x < width {
                sum += Double(data[y * width + x]) / 255; n += 1
            }
        }
        return sum / max(n, 1)
    }

    /// Intersection over union of the two masks at half, same size.
    func iou(_ other: MaskBitmap) -> Double {
        precondition(width == other.width && height == other.height)
        var both = 0, either = 0
        for i in 0..<data.count {
            let a = data[i] > 127, b = other.data[i] > 127
            if a && b { both += 1 }
            if a || b { either += 1 }
        }
        return either == 0 ? 1 : Double(both) / Double(either)
    }
}

/// BiRefNet-lite through `SubjectSegmenter` (docs/Retouch.md §5, §11):
/// skipped when the package is not bundled.
final class SubjectSegmenterTests: XCTestCase {
    /// Loaded once for the class; the first test to ask pays the load and
    /// prints its time.
    static let bundled = SharedModel<SubjectSegmenter> {
        guard let entry = ModelRegistry.shared.entry(id: "birefnet-lite"), entry.status == .bundled else { return nil }
        let start = Date()
        guard let model = try? await SubjectSegmenter.load(entry, computeUnits: .cpuAndGPU) else { return nil }
        print(String(format: "BIREFNET load %.1f s (compile cached after the first run)", Date().timeIntervalSince(start)))
        return model
    }

    func segmenter() async throws -> SubjectSegmenter {
        try XCTSkipUnless(ModelRegistry.shared.entry(id: "birefnet-lite")?.status == .bundled, "BiRefNet-lite not bundled")
        let model = await Self.bundled.value
        return try XCTUnwrap(model, "BiRefNet-lite failed to load")
    }

    /// The portrait: the subject covers a plausible share of the frame,
    /// the face is inside it, the top corner is not, and two runs agree.
    func testPortraitMaskCoversTheSubject() async throws {
        let model = try await segmenter()
        XCTAssertEqual(model.inputSize, 1024)
        let image = try PortraitAsset.image(longEdge: 1536)
        let t0 = Date()
        let first = try model.segment(image)
        let t1 = Date()
        let second = try model.segment(image)
        let t2 = Date()
        print(String(format: "BIREFNET portrait: first %.0f ms, second %.0f ms, mask %dx%d, coverage %.1f%%, face %.2f",
                     t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000, first.width, first.height,
                     first.coverage * 100, first.mean(in: PortraitAsset.faceBox)))
        XCTAssertEqual(first.width, 1024)
        XCTAssertEqual(first.height, 1024)
        XCTAssertTrue((0.3...0.8).contains(first.coverage), "coverage \(first.coverage)")
        XCTAssertGreaterThan(first.mean(in: PortraitAsset.faceBox), 0.5, "the face is subject")
        XCTAssertGreaterThan(first.coverage(in: PortraitAsset.faceBox), 0.9)
        XCTAssertLessThan(first.coverage(in: CGRect(x: 0, y: 0, width: 0.1, height: 0.1)), 0.2, "the top-left corner is backdrop")
        XCTAssertGreaterThanOrEqual(first.iou(second), 0.99)
    }

    /// A sensor-orientation image with the turn that makes it upright
    /// gives the upright mask turned back into the sensor frame.
    func testMaskComesBackInTheSensorFrame() async throws {
        let model = try await segmenter()
        let upright = try PortraitAsset.image(longEdge: 1024)
        // What a camera held sideways records: the upright picture turned
        // so that cw90 puts it right again.
        let sensor = try XCTUnwrap(UprightImage.rotated(upright, by: .cw270))
        XCTAssertEqual(sensor.width, upright.height)
        let uprightMask = try model.segment(upright)
        let sensorMask = try model.segment(sensor, rotation: .cw90)
        XCTAssertEqual(sensorMask.width, uprightMask.height)
        XCTAssertEqual(sensorMask.height, uprightMask.width)
        // Every upright pixel, read where the rotation puts it.
        let size = CGSize(width: sensorMask.width, height: sensorMask.height)
        var both = 0, either = 0
        for y in 0..<uprightMask.height {
            for x in 0..<uprightMask.width {
                let p = ImageRotation.cw90.sensorPoint(fromImagePoint: CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5),
                                                       sensorSize: size)
                let a = uprightMask.data[y * uprightMask.width + x] > 127
                let b = sensorMask.data[Int(p.y) * sensorMask.width + Int(p.x)] > 127
                if a && b { both += 1 }
                if a || b { either += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(Double(both) / Double(max(either, 1)), 0.99)
    }

    /// A dark disc on a plain light background: the disc is subject, the
    /// corners are not.
    func testSyntheticObjectOnAPlainBackground() async throws {
        let model = try await segmenter()
        let width = 1024, height = 768
        let centre = SIMD2<Double>(512, 384), radius = 170.0
        let image = SyntheticImage.make(width: width, height: height) { x, y in
            let d = (SIMD2<Double>(Double(x), Double(y)) - centre)
            return (d.x * d.x + d.y * d.y).squareRoot() < radius ? (30, 40, 110) : (205, 205, 200)
        }
        let mask = try model.segment(image)
        let inner = CGRect(x: (centre.x - radius * 0.6) / Double(width), y: (centre.y - radius * 0.6) / Double(height),
                           width: radius * 1.2 / Double(width), height: radius * 1.2 / Double(height))
        print(String(format: "BIREFNET synthetic: disc %.2f, corners %.3f", mask.mean(in: inner),
                     mask.mean(in: CGRect(x: 0, y: 0, width: 0.15, height: 0.15))))
        XCTAssertGreaterThan(mask.mean(in: inner), 0.5, "the disc is the subject")
        for corner in [CGRect(x: 0, y: 0, width: 0.15, height: 0.15), CGRect(x: 0.85, y: 0, width: 0.15, height: 0.15),
                       CGRect(x: 0, y: 0.85, width: 0.15, height: 0.15), CGRect(x: 0.85, y: 0.85, width: 0.15, height: 0.15)] {
            XCTAssertLessThan(mask.mean(in: corner), 0.5, "the background is not")
        }
    }

    /// `sensorMask` is the exact inverse of `UprightImage.rotated` for
    /// every turn: a picture turned upright and read back lands on its
    /// own pixels.
    func testSensorMaskInvertsTheUprightTurn() throws {
        let width = 5, height = 3
        let original = SyntheticImage.make(width: width, height: height) { x, y in
            let v = UInt8(y * width + x + 1)
            return (v, v, v)
        }
        let originalBytes = SyntheticImage.redBytes(original)
        for rotation in ImageRotation.allCases {
            let upright = try XCTUnwrap(UprightImage.rotated(original, by: rotation))
            let mask = MaskBitmap(width: upright.width, height: upright.height, data: SyntheticImage.redBytes(upright))
            let back = SubjectSegmenter.sensorMask(mask, rotation: rotation)
            XCTAssertEqual(back.width, width, "\(rotation)")
            XCTAssertEqual(back.height, height, "\(rotation)")
            XCTAssertEqual(back.data, originalBytes, "\(rotation)")
        }
    }

    /// The loader refuses what it cannot run rather than pretending.
    func testLoadRefusesOtherKindsAndMissingPackages() async {
        let manifest = ModelManifest(
            id: "fake", displayName: "Fake", purpose: "", version: 1, kind: .promptedSegmentation,
            licence: ModelManifest.Licence(name: "MIT", url: URL(string: "https://example.org")!, commercialUse: true),
            sourceURL: URL(string: "https://example.org")!, sizeMB: 1, inputSize: 64,
            packages: [ModelManifest.Package(name: "Fake.mlpackage", sha256: "00")])
        let prompted = ModelEntry(manifest: manifest, status: .installed, location: FileManager.default.temporaryDirectory)
        do {
            _ = try await SubjectSegmenter.load(prompted, computeUnits: .cpuOnly)
            XCTFail("loaded a prompted model as a subject model")
        } catch let error as SubjectSegmenterError {
            XCTAssertEqual(error, .wrongKind("fake"))
        } catch {
            XCTFail("\(error)")
        }
        var subject = manifest
        subject.kind = .subjectSegmentation
        do {
            _ = try await SubjectSegmenter.load(ModelEntry(manifest: subject, status: .installed,
                                                           location: FileManager.default.temporaryDirectory),
                                                computeUnits: .cpuOnly)
            XCTFail("loaded a package that is not there")
        } catch let error as CoreMLStore.StoreError {
            XCTAssertTrue(String(describing: error).contains("Fake.mlpackage"))
        } catch {
            XCTFail("\(error)")
        }
    }
}
