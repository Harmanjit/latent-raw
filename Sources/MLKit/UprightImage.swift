import Foundation
import CoreGraphics
import PixelEngine

/// The turn that puts a sensor render the right way up for Vision.
///
/// A copy of `RedEyeDetector.rotated(_:by:)` for now: Wave 1 (W1-E) owns
/// RedEyeDetector.swift and makes it call this one, at which point the
/// copy there goes. Keep the two the same until then (RedEyeDetectorTests
/// cover the original; the same test could run here).
enum UprightImage {
    /// `image` turned as `rotation` turns the sensor into what the user
    /// sees (`ImageRotation.imagePoint`), so faces are upright for Vision.
    static func rotated(_ image: CGImage, by rotation: ImageRotation) -> CGImage? {
        guard rotation != .none else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let out = rotation.imageSize(forSensorSize: CGSize(width: w, height: h))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(out.width), height: Int(out.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Core Graphics draws y-up. With the source drawn at (0, 0, w, h),
        // these place its top-left pixel (x, y) where `imagePoint` puts it.
        switch rotation {
        case .none: break
        case .cw90: context.concatenate(CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w))
        case .cw180: context.concatenate(CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h))
        case .cw270: context.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0))
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }
}
