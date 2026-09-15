// The HDR dialog's deghost overlay: where deghosting took each part of the
// picture from a single photo, drawn over the preview.

import CoreGraphics
import Foundation
import PixelEngine

/// Draws where deghosting left photos out, over a preview.
///
/// **What it shows.** Wherever something moved, deghosting keeps one photo
/// and leaves the others out. Each such area is tinted with the colour of
/// the photo it now comes from (the dialog shows the same colour beside
/// that photo) and outlined, and where two such areas meet, the line
/// between them is drawn too. So the overlay answers "where did deghosting
/// act, and which photo shows there", as Lightroom's red overlay answers only
/// the first.
///
/// **Readable without telling colours apart.** Red alone is the colour
/// people with the commonest colour-vision deficiencies see worst, and a
/// tint alone vanishes over a matching sky. So:
/// - the colours are the Okabe–Ito palette (orange, sky blue, bluish green,
///   yellow, blue, vermillion, reddish purple), chosen so that people with
///   protanopia, deuteranopia or tritanopia can still tell them apart;
/// - every area and every border between areas is outlined in white with a
///   black line inside it, which shows on a bright sky and a dark street
///   alike, so the shapes read with no colour at all;
/// - the tint is translucent (40%), so the picture underneath stays visible.
public enum HDRDeghostOverlay {
    /// The Okabe–Ito colours, sRGB 0...255, in the order frames use them.
    public static let palette: [(red: UInt8, green: UInt8, blue: UInt8)] = [
        (230, 159, 0), (86, 180, 233), (0, 158, 115), (240, 228, 66), (0, 114, 178), (213, 94, 0), (204, 121, 167),
    ]

    /// The palette's colours in words, for VoiceOver and the help.
    public static let paletteNames = ["orange", "sky blue", "bluish green", "yellow", "blue", "vermillion",
                                      "reddish purple"]

    /// The colour of frame `index` of the analysis (brightest first): the
    /// palette in turn, starting again after the seventh.
    public static func colour(forFrame index: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        palette[paletteIndex(forFrame: index)]
    }

    /// The name of `colour(forFrame:)`.
    public static func colourName(forFrame index: Int) -> String {
        paletteNames[paletteIndex(forFrame: index)]
    }

    private static func paletteIndex(forFrame index: Int) -> Int {
        ((index % palette.count) + palette.count) % palette.count
    }

    /// How much of an area the tint covers.
    static let tintOpacity: Double = 0.4

    /// Which frame each quarter-size mask pixel comes from, and whether
    /// deghosting acted there: the reduced masks of a preview, combined.
    struct Ownership {
        let width: Int
        let height: Int
        /// The frame each pixel comes from; -1 where no frame was left out.
        let owner: [Int]
        /// How far the most left-out frame is left out, 0...255.
        let strength: [UInt8]
    }

    /// Where any frame is left out by at least half, the frame that shows
    /// there: the frame (other than the reference) left out least, when it
    /// is left out by under half, otherwise the reference, which is never
    /// masked. Nil when no frame has a mask.
    static func ownership(masks: [HDRGhostMask?], reference: Int) -> Ownership? {
        guard let first = masks.compactMap({ $0 }).first else { return nil }
        let (w, h) = (first.width, first.height)
        let masked = masks.enumerated().compactMap { index, mask -> (Int, [UInt8])? in
            guard let mask, index != reference, mask.width == w, mask.height == h else { return nil }
            return (index, mask.weights)
        }
        var owner = [Int](repeating: -1, count: w * h)
        var strength = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            var most: UInt8 = 0, least: UInt8 = 255, leastFrame = reference
            for (frame, weights) in masked {
                let weight = weights[i]
                most = max(most, weight)
                if weight < least { least = weight; leastFrame = frame }
            }
            strength[i] = most
            // Where the masks fade out, the frame the area comes from still
            // counts, so the outline can follow the fade smoothly.
            guard most > 0 else { continue }
            owner[i] = least < 128 ? leastFrame : reference
        }
        return Ownership(width: w, height: h, owner: owner, strength: strength)
    }

    /// `image` (a preview of a `sensorWidth x sensorHeight` frame, shown
    /// turned by `rotation`) with `ownership` (at quarter size of that
    /// frame) drawn over it.
    static func draw(_ ownership: Ownership, over image: CGImage, sensorWidth: Int, sensorHeight: Int,
                     rotation: ImageRotation) -> CGImage? {
        let (w, h) = (image.width, image.height)
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)

        // Every preview pixel's owner. The preview is the sensor turned by
        // `rotation` and scaled to fit. A pixel is inside an area where the
        // strongest mask, blended between the four nearest mask pixels, is
        // at least half (so outlines run smoothly, not in mask-pixel steps),
        // and belongs to the frame of the strongest of those four.
        let sensor = CGSize(width: sensorWidth, height: sensorHeight)
        let turned = rotation.imageSize(forSensorSize: sensor)
        let scaleX = turned.width / CGFloat(w), scaleY = turned.height / CGFloat(h)
        let mapScale = CGFloat(HDRMergeKernels.maskSpan)
        var owners = [Int](repeating: -1, count: w * h)
        owners.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    // The bitmap's first row is the image's top row.
                    let point = CGPoint(x: (CGFloat(x) + 0.5) * scaleX, y: (CGFloat(y) + 0.5) * scaleY)
                    let s = rotation.sensorPoint(fromImagePoint: point, sensorSize: sensor)
                    // Mask pixel centres sit at the middle of their blocks.
                    let fx = max(0, min(Double(s.x / mapScale) - 0.5, Double(ownership.width - 1)))
                    let fy = max(0, min(Double(s.y / mapScale) - 0.5, Double(ownership.height - 1)))
                    let x0 = Int(fx), y0 = Int(fy)
                    let x1 = min(x0 + 1, ownership.width - 1), y1 = min(y0 + 1, ownership.height - 1)
                    let tx = fx - Double(x0), ty = fy - Double(y0)
                    var blended = 0.0, strongest = -1, strongestValue: UInt8 = 0
                    func tap(_ mx: Int, _ my: Int, _ weight: Double) {
                        let i = my * ownership.width + mx
                        blended += Double(ownership.strength[i]) * weight
                        if ownership.strength[i] > strongestValue {
                            strongestValue = ownership.strength[i]
                            strongest = ownership.owner[i]
                        }
                    }
                    tap(x0, y0, (1 - tx) * (1 - ty))
                    tap(x1, y0, tx * (1 - ty))
                    tap(x0, y1, (1 - tx) * ty)
                    tap(x1, y1, tx * ty)
                    out[y * w + x] = blended >= 127.5 ? strongest : -1
                }
            }
        }

        // Tint, then the outlines: a pixel next to one with another owner
        // (or none) is on an edge, white; the pixel inside it, black.
        let opacity = tintOpacity
        owners.withUnsafeBufferPointer { ownerBuffer in
            nonisolated(unsafe) let owners = ownerBuffer
            nonisolated(unsafe) let pixels = pixels
            @Sendable func owner(_ x: Int, _ y: Int) -> Int {
                owners[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)]
            }
            /// The nearest edge within 2 px, as a distance, or nil.
            @Sendable func edgeDistance(_ x: Int, _ y: Int, _ own: Int) -> Int? {
                for d in 1...2 {
                    if owner(x - d, y) != own || owner(x + d, y) != own || owner(x, y - d) != own
                        || owner(x, y + d) != own { return d }
                }
                return nil
            }
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w {
                    let own = owners[y * w + x]
                    guard own >= 0 else { continue }
                    let i = (y * w + x) * 4
                    switch edgeDistance(x, y, own) {
                    case 1?:
                        pixels[i] = 255; pixels[i + 1] = 255; pixels[i + 2] = 255
                    case 2?:
                        pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0
                    default:
                        let c = colour(forFrame: own)
                        func blend(_ value: UInt8, _ tint: UInt8) -> UInt8 {
                            UInt8(min(255, max(0, (Double(value) * (1 - opacity) + Double(tint) * opacity).rounded())))
                        }
                        pixels[i] = blend(pixels[i], c.red)
                        pixels[i + 1] = blend(pixels[i + 1], c.green)
                        pixels[i + 2] = blend(pixels[i + 2], c.blue)
                    }
                }
            }
        }
        return context.makeImage()
    }
}
