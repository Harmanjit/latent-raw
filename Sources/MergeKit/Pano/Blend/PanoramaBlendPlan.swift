import Foundation

// How a stitch is cut up: the levels of the blend's pyramid, which of them
// are computed per tile and which once for the whole panorama, and the
// tiles with their aprons. PanoramaStitcher.swift explains the method.

/// The shape of one stitch, decided before any full-resolution work.
public struct PanoramaBlendPlan: Sendable, Equatable {
    /// The output image's size.
    public let width: Int
    public let height: Int
    /// Pyramid levels computed inside each tile: levels 0 ..< tiledLevels.
    /// Level `tiledLevels` and coarser are computed once for the whole
    /// panorama, so neighbouring tiles share them exactly. Also the level
    /// the seams are computed at: 1 / 2^tiledLevels of the output (1/8 for
    /// panoramas up to 32,768 px).
    public let tiledLevels: Int
    /// The coarsest pyramid level: the blend has `bands` detail bands
    /// (levels 0 ..< bands) plus the residual at level `bands`.
    public let bands: Int
    /// The typical distance from a seam to the nearer edge of the two photos
    /// meeting there, in output pixels (the median over every seam pixel),
    /// or nil where no seams were found. The bands are chosen from it.
    public let halfOverlap: Double?
    /// Output pixels per tile side (edge tiles are smaller).
    public let tileSize: Int
    /// Extra output pixels each tile computes on every side (clipped at the
    /// panorama's edges) so its kept pixels match a whole-panorama blend:
    /// see `requiredApron`.
    public let apron: Int
    /// Per camera (in layout order): the output pixels it can cover, or nil.
    public let frameBounds: [PixelRegion?]

    public var tilesAcross: Int { (width + tileSize - 1) / tileSize }
    public var tilesDown: Int { (height + tileSize - 1) / tileSize }
    public var tileCount: Int { tilesAcross * tilesDown }
    /// Output pixels per pixel of the seam map and the shared coarse level.
    public var coarseStep: Int { 1 << tiledLevels }

    /// Tile (column, row)'s pixels.
    public func tile(column: Int, row: Int) -> PixelRegion {
        let x = column * tileSize, y = row * tileSize
        return PixelRegion(x: x, y: y, width: min(tileSize, width - x), height: min(tileSize, height - y))
    }

    /// The pixels a tile computes: the tile and its apron, inside the output.
    /// Its origin is a multiple of `coarseStep`, so every level's pixels
    /// line up with the whole panorama's.
    public func window(for tile: PixelRegion) -> PixelRegion {
        let x0 = max(0, tile.x - apron), y0 = max(0, tile.y - apron)
        let x1 = min(width, tile.x + tile.width + apron), y1 = min(height, tile.y + tile.height + apron)
        return PixelRegion(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// The cameras whose pixels can reach a window, in layout order.
    public func cameras(touching window: PixelRegion) -> [Int] {
        frameBounds.indices.filter { index in
            guard let bounds = frameBounds[index] else { return false }
            return bounds.x < window.x + window.width && window.x < bounds.x + bounds.width
                && bounds.y < window.y + window.height && window.y < bounds.y + bounds.height
        }
    }

    /// The most cameras any one tile's window touches.
    public var mostCamerasPerTile: Int {
        var most = 0
        for row in 0..<tilesDown {
            for column in 0..<tilesAcross {
                most = max(most, cameras(touching: window(for: tile(column: column, row: row))).count)
            }
        }
        return most
    }

    /// GPU memory one tile's textures take, in bytes, with `cameras` photos
    /// in its window: per pixel of the largest window, 8 bytes per warped
    /// photo, 16 for the seam labels, and (at 16 bytes a pixel, a third
    /// more for the coarser levels) the photo's pyramid, the blend's sums
    /// and a reduce's scratch, plus the 4-byte weights and the output.
    public func tileTextureBytes(cameras: Int) -> Int {
        let w = min(width, tileSize + 2 * apron), h = min(height, tileSize + 2 * apron)
        let pixels = w * h
        let pyramid = pixels * 16 * 4 / 3, weights = pixels * 4 * 4 / 3
        return pixels * 8 * max(cameras, 1) + pixels * 16 + 2 * pyramid + weights + pixels * 8 + pixels * 2
            + tileSize * tileSize * 8
    }

    /// A generous estimate of the GPU memory a stitch holds at its fullest,
    /// in bytes: one tile's textures (`tileTextureBytes`), the frame cache
    /// (its budget, but at least the largest frame with its mips), and the
    /// whole-panorama coarse levels: the seam labels, the blend's sums per
    /// level, each photo's coarse warp and filled level, and one photo's
    /// coarse pyramid while it is built.
    public func estimatedPeakTextureBytes(frameCacheBytes: Int, largestFrameBytes: Int) -> Int {
        let step = coarseStep
        let coarseWidth = (width + step - 1) / step, coarseHeight = (height + step - 1) / step
        var coarse = coarseWidth * coarseHeight * 16
        for level in tiledLevels...bands {
            coarse += ((width + (1 << level) - 1) >> level) * ((height + (1 << level) - 1) >> level) * 16
        }
        var largestPatch = 0
        for bounds in frameBounds.compactMap({ $0 }) {
            // The photo's patch at the coarse level, with its 4-pixel margins.
            let patch = (bounds.width / step + 10) * (bounds.height / step + 10)
            coarse += patch * (8 + 16)
            largestPatch = max(largestPatch, patch)
        }
        // Colour and weights per level (a third more for the coarser ones),
        // and a reduce's scratch.
        coarse += largestPatch * (16 + 4) * 4 / 3 + largestPatch * 20
        // A tenth more: every texture's allocation rounds up to whole pages,
        // which tells on the many small coarse ones.
        let total = tileTextureBytes(cameras: mostCamerasPerTile) + max(frameCacheBytes, largestFrameBytes * 4 / 3)
            + coarse
        return total + total / 10
    }

    // MARK: - Choices

    /// Tiled levels for a panorama: at least 3 (seams at 1/8 scale), more if
    /// the shared coarse level would be wider than 4,096 px, so its textures
    /// stay small.
    public static func tiledLevels(width: Int, height: Int) -> Int {
        var levels = 3
        while (max(width, height) + (1 << levels) - 1) >> levels > 4096 { levels += 1 }
        return levels
    }

    /// The number of bands for a typical seam-to-edge distance of
    /// `halfOverlap` output pixels.
    ///
    /// Level k's weights are the seam mask blurred by the reduce filter k
    /// times, a spread of about 0.65 x 2^k pixels (the filter's variance is
    /// 1.25 per level, growing fourfold each level), so a band hands over
    /// across about ±1.3 x 2^k pixels. The coarsest band that still hands
    /// over inside the overlap has 1.3 x 2^bands <= halfOverlap. Never
    /// fewer than tiledLevels + 1: the shared coarse level needs one reduce
    /// of its own so uncovered pixels next to a photo are filled from
    /// coarser values (see `mergePanoBlendCollapse`). At most 12, and no
    /// coarser than the panorama itself.
    public static func bands(halfOverlap: Double?, tiledLevels: Int, width: Int, height: Int) -> Int {
        let fewest = tiledLevels + 1
        let size = Double(max(width, height))
        let most = max(fewest, min(12, Int(floor(log2(size)))))
        guard let halfOverlap, halfOverlap > 1.3 else { return fewest }
        return min(max(Int(floor(log2(halfOverlap / 1.3))), fewest), most)
    }

    /// The smallest apron (a multiple of 2^tiledLevels) that lets a tile
    /// compute its kept pixels exactly as a whole-panorama blend would.
    ///
    /// Derived by following which pixels of each level are exact, level by
    /// level, from a window of tile plus apron: a reduce's pixel is exact if
    /// all six taps are (a 1-pixel-wide window loses about one coarse pixel
    /// on the left and two on the right); an expand's if its three coarse
    /// taps are; each band needs its Gaussian level and the expanded filled
    /// level coarser than it; the shared level (`tiledLevels`) is exact
    /// everywhere; and the collapse needs each band and the expanded coarser
    /// result. The apron grows until level 0's exact pixels cover the tile.
    /// Pixel-wise stages (warps, seam labels, the log) change nothing.
    public static func requiredApron(tiledLevels: Int) -> Int {
        let unit = 1 << tiledLevels
        var apron = unit
        while !apronSuffices(apron, tiledLevels: tiledLevels) { apron += unit }
        return apron
    }

    /// Whether `apron` suffices (see `requiredApron`): intervals [lower, upper)
    /// of exact pixels, per level, for a tile far from the panorama's edges.
    static func apronSuffices(_ apron: Int, tiledLevels: Int) -> Bool {
        typealias Exact = (lower: Int, upper: Int)
        let tile = 64 << tiledLevels
        let everything: Exact = (Int.min / 4, Int.max / 4)
        func floorDiv(_ a: Int, _ b: Int) -> Int { Int((Double(a) / Double(b)).rounded(.down)) }
        func ceilDiv(_ a: Int, _ b: Int) -> Int { Int((Double(a) / Double(b)).rounded(.up)) }
        // j is exact when fine pixels 2j - 2 ... 2j + 3 all are.
        func reduce(_ e: Exact) -> Exact { (ceilDiv(e.lower + 2, 2), floorDiv(e.upper - 4, 2) + 1) }
        // i is exact when coarse pixels i/2 - 1 ... i/2 + 1 all are.
        func expand(_ e: Exact) -> Exact {
            if e.lower <= everything.lower { return everything }
            return (2 * (e.lower + 1), 2 * (e.upper - 2) + 2)
        }
        func both(_ a: Exact, _ b: Exact) -> Exact { (max(a.lower, b.lower), min(a.upper, b.upper)) }

        var gaussian: [Exact] = [(-apron, tile + apron)]
        for _ in 1..<max(tiledLevels, 1) { gaussian.append(reduce(gaussian.last!)) }
        var filledCoarser = everything
        var bandsExact = [Exact](repeating: everything, count: tiledLevels)
        for level in stride(from: tiledLevels - 1, through: 0, by: -1) {
            let filled = both(gaussian[level], expand(filledCoarser))
            bandsExact[level] = filled
            filledCoarser = filled
        }
        var result = everything
        for level in stride(from: tiledLevels - 1, through: 0, by: -1) {
            result = both(bandsExact[level], expand(result))
        }
        return result.lower <= 0 && result.upper >= tile
    }
}
