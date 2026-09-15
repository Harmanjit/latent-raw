import XCTest
import simd
@testable import MergeKit

/// The projection maths in PanoramaAPI.swift round-trips: canvas pixel to
/// direction and back, and frame pixel to direction and back, for every
/// projection. The Metal kernels are checked against these functions.
final class PanoramaMathTests: XCTestCase {
    private func rotationY(_ angle: Double) -> [Double] {
        [cos(angle), 0, sin(angle), 0, 1, 0, -sin(angle), 0, cos(angle)]
    }

    func testCanvasRoundTripsForEveryProjection() {
        for projection in [PanoramaProjection.perspective, .cylindrical, .spherical] {
            let canvas = PanoramaCanvas(projection: projection, pixelsPerRadian: 3000, origin: SIMD2(-4000, -1500),
                                        width: 8000, height: 3000)
            for p in [SIMD2<Double>(0, 0), SIMD2(4000, 1500), SIMD2(7999.5, 10), SIMD2(123.25, 2999)] {
                guard let d = PanoramaMath.direction(canvasPixel: p, canvas: canvas),
                      let back = PanoramaMath.canvasPixel(direction: d, canvas: canvas) else {
                    return XCTFail("\(projection) lost \(p)")
                }
                XCTAssertEqual(simd_length(d), 1, accuracy: 1e-12)
                XCTAssertLessThan(simd_distance(back, p), 1e-6, "\(projection) \(p) -> \(back)")
            }
        }
    }

    func testFramePixelRoundTripsAndMatchesTheCameraConvention() {
        let camera = PanoramaCamera(frameIndex: 0, rotation: rotationY(0.4), focalLengthPixels: 2500,
                                    principalPoint: SIMD2(2000, 3000), width: 4000, height: 6000, exposureGain: 1)
        for p in [SIMD2<Double>(0, 0), SIMD2(2000, 3000), SIMD2(3999, 5999)] {
            let d = PanoramaMath.direction(framePixel: p, camera: camera)
            let back = PanoramaMath.framePixel(direction: d, camera: camera)!
            XCTAssertLessThan(simd_distance(back, p), 1e-6)
        }
        // The photo's centre looks 0.4 rad to the right of the panorama's centre,
        // on the horizon; +y is down, so a pixel below the centre looks down.
        let centre = PanoramaMath.direction(framePixel: SIMD2(2000, 3000), camera: camera)
        XCTAssertEqual(atan2(centre.x, centre.z), 0.4, accuracy: 1e-12)
        XCTAssertEqual(centre.y, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(PanoramaMath.direction(framePixel: SIMD2(2000, 4000), camera: camera).y, 0)
        XCTAssertNil(PanoramaMath.framePixel(direction: SIMD3(0, 0, -1), camera: camera), "behind the camera")
    }
}
