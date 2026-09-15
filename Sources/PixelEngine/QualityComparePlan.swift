import Foundation
import CoreGraphics

/// The geometry and choices behind the export sheet's quality comparison,
/// kept apart from the window so they can be tested.
///
/// The window shows one rendered export encoded at several qualities, at
/// 100% with one shared pan. Decoding each whole encode to show a few
/// hundred pixels of it would hold a full-size copy per pane, so each
/// pane shows a tile: the visible part plus a margin, cut from the render
/// on the encoder's block grid, encoded at that pane's quality and decoded.
/// JPEG codes 8x8 blocks in 16x16 macroblocks and HEVC 64x64 coding tree
/// units; a tile that starts on a multiple of 64 lines up with both, so
/// its JPEG blocks are the whole file's blocks and look exactly as they
/// will in the file. (HEVC's prediction also reads neighbouring blocks, so
/// a HEIC tile's edges can differ slightly from the whole file's.) The byte
/// sizes shown are always whole-file encodes.
public enum QualityComparePlan {
    public static let block = 64
    public static let paneCounts = 2...4
    public static let qualityRange: ClosedRange<Float> = 0.3...1

    /// `count` qualities including `chosen`, a tenth apart below it where
    /// the range allows and a twentieth above otherwise, lowest first.
    public static func defaultQualities(chosen: Float, count: Int) -> [Float] {
        let n = min(max(count, paneCounts.lowerBound), paneCounts.upperBound)
        func step(_ q: Float) -> Float { (q * 100).rounded() / 100 }
        let start = step(min(max(chosen, qualityRange.lowerBound), qualityRange.upperBound))
        var picked: [Float] = [start]
        let below: [Float] = [1, 2, 3].map { (k: Float) -> Float in start - k / 10 }
        let above: [Float] = [1, 2, 3, 4, 5, 6].map { (k: Float) -> Float in start + k / 20 }
        for candidate in below + above {
            let q = step(candidate)
            if picked.count < n, qualityRange.contains(q), !picked.contains(q) { picked.append(q) }
        }
        return picked.sorted()
    }

    /// The part of the image a pane of `view` pixels shows around `center`,
    /// in image pixels (not clamped to the image).
    public static func visibleRect(center: CGPoint, view: CGSize) -> CGRect {
        CGRect(x: (center.x - view.width / 2).rounded(.down), y: (center.y - view.height / 2).rounded(.down),
               width: view.width.rounded(.up), height: view.height.rounded(.up))
    }

    /// The tile to encode for a view: what it shows plus `margin` pixels
    /// all round, its start on the block grid, clipped to the image (an
    /// image's own right and bottom edges end off the grid, as they do in
    /// the file).
    public static func tile(center: CGPoint, view: CGSize, imageWidth: Int, imageHeight: Int, margin: Int = 256) -> CGRect {
        let visible = visibleRect(center: center, view: view)
        func span(_ low: CGFloat, _ high: CGFloat, _ limit: Int) -> (Int, Int) {
            let start = max(0, Int((low - CGFloat(margin)).rounded(.down)) / block * block)
            let endAligned = (Int((high + CGFloat(margin)).rounded(.up)) + block - 1) / block * block
            return (min(start, max(0, (limit - 1) / block * block)), min(max(endAligned, start + block), limit))
        }
        let (x0, x1) = span(visible.minX, visible.maxX, imageWidth)
        let (y0, y1) = span(visible.minY, visible.maxY, imageHeight)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    /// Whether `tile` still holds everything a view shows (within the image).
    public static func covers(_ tile: CGRect, center: CGPoint, view: CGSize, imageWidth: Int, imageHeight: Int) -> Bool {
        let image = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let needed = visibleRect(center: center, view: view).intersection(image)
        return needed.isNull || tile.contains(needed)
    }

    /// The centre moved so a view stays over the image: centred on an axis
    /// where the image is smaller than the view, whole pixels always.
    public static func clampedCenter(_ center: CGPoint, view: CGSize, imageWidth: Int, imageHeight: Int) -> CGPoint {
        func axis(_ c: CGFloat, _ viewLength: CGFloat, _ length: Int) -> CGFloat {
            let l = CGFloat(length)
            guard viewLength < l else { return (l / 2).rounded() }
            return min(max(c, viewLength / 2), l - viewLength / 2).rounded()
        }
        return CGPoint(x: axis(center.x, view.width, imageWidth), y: axis(center.y, view.height, imageHeight))
    }
}
