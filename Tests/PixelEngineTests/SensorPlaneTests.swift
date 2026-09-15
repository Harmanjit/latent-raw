import XCTest
import Metal
@testable import PixelEngine
@testable import RawCore

final class SensorPlaneTests: XCTestCase {
    func testCopyIsPageAlignedAndExact() throws {
        let source: [UInt16] = (0..<100_003).map { UInt16(truncatingIfNeeded: $0 &* 7) }
        let plane = try XCTUnwrap(source.withUnsafeBufferPointer { SensorPlane(copying: $0) })
        let page = Int(getpagesize())
        XCTAssertEqual(Int(bitPattern: plane.pointer) % page, 0)
        XCTAssertEqual(plane.allocationLength % page, 0)
        XCTAssertGreaterThanOrEqual(plane.allocationLength, source.count * 2)
        XCTAssertEqual(Array(plane.samples), source)
    }

    /// A peer that claims more samples than the surface holds is refused,
    /// so a compromised decoder can't make the app read past the end.
    func testAdoptionRejectsACountLargerThanTheSurface() throws {
        let source = [UInt16](repeating: 1, count: 1000)
        let plane = try XCTUnwrap(source.withUnsafeBufferPointer { SensorPlane(copying: $0) })
        let capacity = plane.allocationLength / 2
        XCTAssertNil(SensorPlane(surface: plane.surface, count: capacity + 1))
        XCTAssertNil(SensorPlane(surface: plane.surface, count: 0))
        XCTAssertNotNil(SensorPlane(surface: plane.surface, count: capacity))
    }

    /// The point of the exercise: the GPU buffer is the plane's own
    /// memory, not a copy of it.
    func testSessionBufferIsThePlaneItself() throws {
        let path = try TestAssets.d750Path()

        let file = try RawFile(path: path)
        let plane = try XCTUnwrap(file.sensorPlane)
        let session = try ImageSession(file: file, gpu: try GPUContext())
        XCTAssertEqual(session.sensorBuffer.contents(), plane.pointer)
        XCTAssertEqual(plane.count, file.summary.rawWidth * file.summary.rawHeight)
    }

    func testMetadataOnlyOpenHasNoPlaneButKeepsPreview() throws {
        let path = try TestAssets.d750Path()

        let file = try RawFile(path: path, metadataOnly: true)
        XCTAssertNil(file.sensorPlane)
        XCTAssertNil(file.rawSensorPlane())
        XCTAssertNotNil(file.embeddedJPEGPreview())
    }
}
