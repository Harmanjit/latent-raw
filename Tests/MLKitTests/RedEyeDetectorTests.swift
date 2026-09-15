import XCTest
import CoreGraphics
import PixelEngine
@testable import MLKit

/// The Auto button's pieces that don't need a face: the check that an eye
/// is red, the turn that puts faces upright, and the way back to sensor
/// coordinates.
final class RedEyeDetectorTests: XCTestCase {
    /// 400 x 200 sRGB: skin, a red-eyed pupil at (100, 100) and a brown eye
    /// with a dark pupil at (300, 100), each with a catchlight.
    static func eyes() -> CGImage {
        let context = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        func disc(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: (CGFloat, CGFloat, CGFloat)) {
            context.setFillColor(red: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
            // CGContext is y-up: flip so coordinates read top-left.
            context.fillEllipse(in: CGRect(x: x - r, y: 200 - y - r, width: 2 * r, height: 2 * r))
        }
        context.setFillColor(red: 224 / 255, green: 172 / 255, blue: 140 / 255, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        for x: CGFloat in [100, 300] { disc(x, 100, 20, (120, 70, 40)) }
        disc(100, 100, 10, (200, 40, 40))
        disc(300, 100, 10, (30, 25, 25))
        for x: CGFloat in [97, 297] { disc(x, 97, 3, (255, 255, 255)) }
        return context.makeImage()!
    }

    func testOnlyRedPupilsAreProposed() {
        let image = Self.eyes()
        XCTAssertGreaterThan(RedEyeDetector.redFraction(in: image, centre: CGPoint(x: 100, y: 100), radius: 10), 0.5)
        XCTAssertEqual(RedEyeDetector.redFraction(in: image, centre: CGPoint(x: 300, y: 100), radius: 10), 0)
        XCTAssertEqual(RedEyeDetector.redFraction(in: image, centre: CGPoint(x: 200, y: 50), radius: 10), 0, "skin")
        let red = RedEyeDetector.redCandidates([.init(centre: CGPoint(x: 100, y: 100), radius: 20),
                                                .init(centre: CGPoint(x: 300, y: 100), radius: 20)], in: image)
        XCTAssertEqual(red, [.init(centre: CGPoint(x: 100, y: 100), radius: 20)])
    }

    func testNoFacesNoSpots() {
        XCTAssertTrue(RedEyeDetector.detect(in: Self.eyes(), rotation: .none).isEmpty)
    }

    /// The turned image has each pixel where `ImageRotation.imagePoint`
    /// says, and a spot found there maps back to the sensor point.
    func testRotationRoundTripsToSensorCoordinates() throws {
        let w = 40, h = 20
        let context = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        // Top-left pixel (5, 3).
        context.fill(CGRect(x: 5, y: h - 3 - 1, width: 1, height: 1))
        let sensorImage = try XCTUnwrap(context.makeImage())
        let sensorSize = CGSize(width: w, height: h)
        let marker = CGPoint(x: 5.5, y: 3.5)

        for rotation in ImageRotation.allCases {
            let turned = try XCTUnwrap(RedEyeDetector.rotated(sensorImage, by: rotation))
            let expectedSize = rotation.imageSize(forSensorSize: sensorSize)
            XCTAssertEqual(CGSize(width: turned.width, height: turned.height), expectedSize, "\(rotation)")
            let data = try XCTUnwrap(turned.dataProvider?.data as Data?)
            let bytesPerRow = turned.bytesPerRow
            var found: CGPoint?
            for y in 0..<turned.height {
                for x in 0..<turned.width where data[y * bytesPerRow + x * 4] > 128 {
                    found = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                }
            }
            let expected = rotation.imagePoint(fromSensorPoint: marker, sensorSize: sensorSize)
            XCTAssertEqual(found, expected, "\(rotation)")

            let spot = RedEyeDetector.spot(for: .init(centre: expected, radius: 4), rotation: rotation,
                                           sensorImageSize: sensorSize)
            XCTAssertEqual(Double(spot.centre.x), 5.5 / 40, accuracy: 1e-6, "\(rotation)")
            XCTAssertEqual(Double(spot.centre.y), 3.5 / 20, accuracy: 1e-6, "\(rotation)")
            XCTAssertEqual(spot.radius, 0.2, accuracy: 1e-6)
        }
    }
}
