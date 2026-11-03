import Foundation
import CoreGraphics

/// How big an exported file is, the ways Lightroom's Image Sizing offers:
/// a long or short edge, a box (Width & Height, or Dimensions, which turns
/// with the photo), a number of megapixels, or a percentage. Each comes
/// down to one number, the file's long edge in pixels
/// (`targetLongEdge`), which the render and the resampler already work
/// to, so every mode gets the same binning and Lanczos filter.
///
/// **Don't Enlarge** (on by default) never makes a file bigger than the
/// cropped photo; off, a smaller photo is enlarged with the same filter.
public struct ExportSizing: Sendable, Hashable, Codable {
    public enum Mode: String, Sendable, Codable, CaseIterable {
        case longEdge, shortEdge, widthHeight, dimensions, megapixels, percentage

        public var title: String {
            switch self {
            case .longEdge: "Long edge"
            case .shortEdge: "Short edge"
            case .widthHeight: "Width & height"
            case .dimensions: "Dimensions"
            case .megapixels: "Megapixels"
            case .percentage: "Percentage"
            }
        }
    }

    public var mode: Mode
    public var longEdge: Int
    public var shortEdge: Int
    /// Width & Height: the box as given. Dimensions: the larger number
    /// bounds the long edge and the smaller the short, whichever way the
    /// photo is turned.
    public var width: Int
    public var height: Int
    public var megapixels: Double
    public var percentage: Double
    public var dontEnlarge: Bool

    public init(mode: Mode = .longEdge, longEdge: Int = 2048, shortEdge: Int = 1365, width: Int = 2048,
                height: Int = 2048, megapixels: Double = 12, percentage: Double = 50, dontEnlarge: Bool = true) {
        self.mode = mode; self.longEdge = longEdge; self.shortEdge = shortEdge
        self.width = width; self.height = height; self.megapixels = megapixels
        self.percentage = percentage; self.dontEnlarge = dontEnlarge
    }

    /// The largest edge an export may ask for: past this the render and
    /// the encoders run out of room.
    public static let maximumEdge = 65_000

    /// The long edge, in pixels, of the file made from a cropped and
    /// turned photo `width` x `height` pixels at full size. Never below 1;
    /// never above the photo's own long edge with Don't Enlarge.
    public func targetLongEdge(width w: Int, height h: Int) -> Int {
        let w = max(1, w), h = max(1, h)
        let long = Double(max(w, h)), short = Double(min(w, h))
        let scale: Double
        switch mode {
        case .longEdge:
            scale = Double(max(1, longEdge)) / long
        case .shortEdge:
            scale = Double(max(1, shortEdge)) / short
        case .widthHeight:
            scale = min(Double(max(1, width)) / Double(w), Double(max(1, height)) / Double(h))
        case .dimensions:
            let boxLong = Double(max(1, max(width, height))), boxShort = Double(max(1, min(width, height)))
            scale = min(boxLong / long, boxShort / short)
        case .megapixels:
            let pixels = max(0.01, megapixels.isFinite ? megapixels : 1) * 1_000_000
            scale = (pixels / (long * short)).squareRoot()
        case .percentage:
            scale = max(1, percentage.isFinite ? percentage : 100) / 100
        }
        var target = Int((long * scale).rounded())
        if dontEnlarge { target = min(target, Int(long)) }
        return min(max(1, target), Self.maximumEdge)
    }

    /// A short description for a preset or a summary: "2048 px long edge".
    public var summary: String {
        switch mode {
        case .longEdge: "\(longEdge) px long edge"
        case .shortEdge: "\(shortEdge) px short edge"
        case .widthHeight: "within \(width) × \(height) px"
        case .dimensions: "within \(max(width, height)) × \(min(width, height)) px"
        case .megapixels: String(format: "%g megapixels", megapixels)
        case .percentage: String(format: "%g%%", percentage)
        }
    }
}

extension ExportPlan {
    /// The long edge to export at for `sizing`, given the photo's raw size,
    /// crop and turn, and whether that enlarges it. Nil target: full size.
    public static func target(for sizing: ExportSizing, rawWidth: Int, rawHeight: Int, crop: CropParameters,
                              rotation: ImageRotation) -> (maxLongEdge: Int?, enlarges: Bool) {
        let canvas = CropFrame(sensorSize: CGSize(width: rawWidth, height: rawHeight), crop: crop,
                               rotation: rotation).canvasSize
        let w = max(1, Int(canvas.width.rounded())), h = max(1, Int(canvas.height.rounded()))
        let target = sizing.targetLongEdge(width: w, height: h)
        if target == max(w, h) { return (nil, false) }
        return (target, target > max(w, h))
    }
}
