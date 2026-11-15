import SwiftUI
import CoreGraphics
import PixelEngine

/// The reference photo's scopes, for Scope menu › Overlay Reference: its
/// histogram and vectorscope drawn faintly with the active photo's, so the
/// colour of one photo can be matched to another.
///
/// Measured from the Reference pane's own analysis render (the pane is a
/// view-only `EditorModel`, `DevelopViewState.pane`) whenever it renders,
/// and kept until the reference changes or goes, so a locked reference
/// still overlays after Reference view closes.
struct ReferenceScopes {
    var histogram: Histogram?
    var vectorscope: Vectorscope?
}

extension EditorModel {
    /// This model's scopes for use as a reference: the histogram and the
    /// vectorscope of its last analysis render, whether or not it measures
    /// scopes of its own (the Reference pane does not). Nil with no render.
    func measureReferenceScopes() -> ReferenceScopes? {
        guard let analysisTexture else { return nil }
        let histogram = histogramCalculator?.compute(from: analysisTexture, inputIsLinear: true)
        let vectorscope = scopeCalculator?.computeVectorscope(from: analysisTexture, inputIsLinear: true)
        guard histogram != nil || vectorscope != nil else { return nil }
        return ReferenceScopes(histogram: histogram, vectorscope: vectorscope)
    }
}

/// The reference's vectorscope as an outline: the cells its colours fill,
/// and, among them, the edge cells that border an empty one.
enum ReferenceScopeOutline {
    /// What a cell is.
    enum Cell: UInt8 { case empty = 0, inside = 1, edge = 2 }

    /// The density (square-root scaled against the peak, as the scope is
    /// drawn) below which a cell counts as empty: low enough to take in a
    /// photo's whole spread, high enough that stray pixels don't speckle.
    static let threshold: Float = 0.06

    /// `Vectorscope.size` squared cells, row-major like the counts.
    static func cells(of v: Vectorscope) -> [Cell] {
        let n = Vectorscope.size
        guard v.peak > 0, v.counts.count == n * n else { return [Cell](repeating: .empty, count: n * n) }
        let scale = 1 / Float(v.peak).squareRoot()
        let filled = v.counts.map { Float($0).squareRoot() * scale >= threshold }
        var cells = [Cell](repeating: .empty, count: n * n)
        for y in 0..<n {
            for x in 0..<n where filled[y * n + x] {
                // An edge borders an empty cell or the plot's own border.
                let bordersEmpty = x == 0 || y == 0 || x == n - 1 || y == n - 1
                    || !filled[y * n + x - 1] || !filled[y * n + x + 1]
                    || !filled[(y - 1) * n + x] || !filled[(y + 1) * n + x]
                cells[y * n + x] = bordersEmpty ? .edge : .inside
            }
        }
        return cells
    }

    /// The outline colour: amber, apart from every hue the scope tints.
    static let colour: (r: Float, g: Float, b: Float) = (1.0, 0.72, 0.25)

    /// The outline as a transparent bitmap the vectorscope's size: a faint
    /// wash where the reference has colour, solid along its edge.
    static func image(of v: Vectorscope) -> CGImage? {
        let n = Vectorscope.size
        let cells = cells(of: v)
        var bytes = [UInt8](repeating: 0, count: n * n * 4)
        for i in 0..<(n * n) {
            let alpha: Float
            switch cells[i] {
            case .empty: continue
            case .inside: alpha = 0.12
            case .edge: alpha = 0.85
            }
            // Premultiplied.
            bytes[i * 4] = UInt8(colour.r * alpha * 255)
            bytes[i * 4 + 1] = UInt8(colour.g * alpha * 255)
            bytes[i * 4 + 2] = UInt8(colour.b * alpha * 255)
            bytes[i * 4 + 3] = UInt8(alpha * 255)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// The reference's histogram drawn behind the active photo's: its
/// luminance as a faint grey area with an amber outline, scaled to its
/// own peak as the active histogram is to its own (the two photos rarely
/// have the same number of pixels).
enum ReferenceHistogramDrawing {
    static func draw(_ reference: Histogram, in context: inout GraphicsContext, size: CGSize) {
        guard reference.peak > 0 else { return }
        let scale = 1.0 / Double(reference.peak).squareRoot()
        let bins = reference.luminance.count
        var outline = Path()
        for (index, count) in reference.luminance.enumerated() {
            let x = size.width * Double(index) / Double(bins - 1)
            let y = size.height * (1.0 - min(Double(count).squareRoot() * scale, 1.0))
            if index == 0 { outline.move(to: CGPoint(x: x, y: y)) } else { outline.addLine(to: CGPoint(x: x, y: y)) }
        }
        var area = outline
        area.addLine(to: CGPoint(x: size.width, y: size.height))
        area.addLine(to: CGPoint(x: 0, y: size.height))
        area.closeSubpath()
        let c = ReferenceScopeOutline.colour
        context.fill(area, with: .color(Color.white.opacity(0.08)))
        context.stroke(outline, with: .color(Color(red: Double(c.r), green: Double(c.g), blue: Double(c.b)).opacity(0.8)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
    }
}
