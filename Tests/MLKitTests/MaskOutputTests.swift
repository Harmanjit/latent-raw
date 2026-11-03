import XCTest
import CoreGraphics
import CoreVideo
@testable import MLKit
@testable import PixelEngine

/// Turning a model's output into mask bytes must survive output it did
/// not expect: NaN values, and a labels file that names more classes than
/// the model has planes. Both used to trap rather than throw.
final class MaskOutputTests: XCTestCase {
    /// NaN becomes 0, infinities clamp, ordinary values scale.
    func testMaskByteMapsNaNToZero() {
        XCTAssertEqual(MLImage.maskByte(.nan), 0)
        XCTAssertEqual(MLImage.maskByte(-.nan), 0)
        XCTAssertEqual(MLImage.maskByte(.infinity), 255)
        XCTAssertEqual(MLImage.maskByte(-.infinity), 0)
        XCTAssertEqual(MLImage.maskByte(0.5), 127)
        XCTAssertEqual(MLImage.maskByte(-1), 0)
        XCTAssertEqual(MLImage.maskByte(2), 255)
    }

    func testClassMapWithNaNDoesNotTrap() {
        let map = SegmentationModel.ClassMap(size: 2, classCount: 1, probabilities: [.nan, 0.5, .infinity, -1])
        XCTAssertEqual(map.mask(classIndices: [0]), MaskBitmap(width: 2, height: 2, data: [0, 127, 255, 0]))
    }

    /// Indices with no plane are skipped, not read past the end.
    func testClassMapSkipsIndicesWithNoPlane() {
        let map = SegmentationModel.ClassMap(size: 4, classCount: 3, probabilities: [Float](repeating: 0.25, count: 48))
        XCTAssertEqual(map.mask(classIndices: [7]).data, [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(map.mask(classIndices: [1, 7, -1]).data, [UInt8](repeating: 63, count: 16))
        XCTAssertEqual(map.mask(classIndices: [0, 1]).data, [UInt8](repeating: 127, count: 16))
    }

    /// A one-component float buffer holding NaN reads as a mask.
    func testFloatPixelBufferWithNaN() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 1, kCVPixelFormatType_OneComponent32Float, nil, &buffer),
                       kCVReturnSuccess)
        let pb = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pb, [])
        let row = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: Float.self)
        row[0] = .nan; row[1] = 1
        CVPixelBufferUnlockBaseAddress(pb, [])
        XCTAssertEqual(try AIMaskGenerator.bitmap(from: pb).data, [0, 255])
    }

    /// The bundled SegFormer with a labels list shorter than its 150
    /// planes: classify refuses with an error instead of handing back a
    /// map whose planes don't line up with the labels.
    func testClassifyRefusesLabelsThatDoNotMatchTheOutput() async throws {
        let ref = ModelRef(id: SegmentationModel.modelID, version: 1)
        guard let entry = ModelRegistry.shared.installed(ref), let location = entry.location else {
            throw XCTSkip("SegFormer package not bundled")
        }
        let model = try await CoreMLStore.load(entry.manifest.packages[0], of: entry.manifest, at: location,
                                               computeUnits: .cpuAndGPU)
        let segmenter = SegmentationModel(model: model, labels: (0..<19).map { "class \($0)" })
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage())
        XCTAssertThrowsError(try segmenter.classify(image)) { error in
            guard case SegmentationModelError.unexpectedOutput = error else { return XCTFail("\(error)") }
        }
    }
}
