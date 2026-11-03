import SwiftUI

/// The composition guides the crop tool draws over the rectangle, as in
/// Lightroom's Tools › Crop Guide Overlay. O cycles them; ⇧O turns the
/// ones that have a direction (the golden spiral and the triangle).
enum CropGuide: String, CaseIterable, Identifiable {
    case thirds, grid, goldenRatio, goldenSpiral, diagonal, triangle, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thirds: "Thirds"
        case .grid: "Grid"
        case .goldenRatio: "Golden Ratio"
        case .goldenSpiral: "Golden Spiral"
        case .diagonal: "Diagonal"
        case .triangle: "Triangle"
        case .none: "None"
        }
    }

    /// How many ways round ⇧O can turn it.
    var orientations: Int {
        switch self {
        case .goldenSpiral: 4
        case .triangle: 2
        default: 1
        }
    }

    var next: CropGuide {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// The overlay's lines inside `rect`. `orientation` counts ⇧O presses:
    /// the spiral is mirrored through its four placements, the
    /// triangle's diagonal swaps corners.
    func path(in rect: CGRect, orientation: Int) -> Path {
        var p = Path()
        func line(_ a: CGPoint, _ b: CGPoint) { p.move(to: a); p.addLine(to: b) }
        func x(_ f: CGFloat) -> CGFloat { rect.minX + rect.width * f }
        func y(_ f: CGFloat) -> CGFloat { rect.minY + rect.height * f }
        func verticals(_ fs: [CGFloat]) { for f in fs { line(CGPoint(x: x(f), y: rect.minY), CGPoint(x: x(f), y: rect.maxY)) } }
        func horizontals(_ fs: [CGFloat]) { for f in fs { line(CGPoint(x: rect.minX, y: y(f)), CGPoint(x: rect.maxX, y: y(f))) } }
        switch self {
        case .none:
            break
        case .thirds:
            verticals([1 / 3, 2 / 3]); horizontals([1 / 3, 2 / 3])
        case .grid:
            // Squares of about a twelfth of the short side.
            let step = max(min(rect.width, rect.height) / 12, 8)
            var gx = rect.minX + step
            while gx < rect.maxX - 1 { line(CGPoint(x: gx, y: rect.minY), CGPoint(x: gx, y: rect.maxY)); gx += step }
            var gy = rect.minY + step
            while gy < rect.maxY - 1 { line(CGPoint(x: rect.minX, y: gy), CGPoint(x: rect.maxX, y: gy)); gy += step }
        case .goldenRatio:
            let a = 1 / Self.phi / Self.phi   // 0.382
            verticals([a, 1 - a]); horizontals([a, 1 - a])
        case .diagonal:
            // 45° from each corner, as far as they go.
            let s = min(rect.width, rect.height)
            line(CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX + s, y: rect.minY + s))
            line(CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX - s, y: rect.minY + s))
            line(CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX + s, y: rect.maxY - s))
            line(CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.maxX - s, y: rect.maxY - s))
        case .triangle:
            // A diagonal, and from the other two corners the perpendiculars to it.
            let flipped = orientation % 2 == 1
            let a = flipped ? CGPoint(x: rect.maxX, y: rect.minY) : CGPoint(x: rect.minX, y: rect.minY)
            let b = flipped ? CGPoint(x: rect.minX, y: rect.maxY) : CGPoint(x: rect.maxX, y: rect.maxY)
            let c = flipped ? CGPoint(x: rect.minX, y: rect.minY) : CGPoint(x: rect.maxX, y: rect.minY)
            let d = flipped ? CGPoint(x: rect.maxX, y: rect.maxY) : CGPoint(x: rect.minX, y: rect.maxY)
            line(a, b)
            line(c, Self.foot(of: c, onLineFrom: a, to: b))
            line(d, Self.foot(of: d, onLineFrom: a, to: b))
        case .goldenSpiral:
            p = Self.spiral(in: rect, orientation: orientation)
        }
        return p
    }

    static let phi: CGFloat = (1 + sqrt(5)) / 2

    static func foot(of p: CGPoint, onLineFrom a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / max(dx * dx + dy * dy, 1e-9)
        return CGPoint(x: a.x + t * dx, y: a.y + t * dy)
    }

    /// The Fibonacci spiral: quarter circles in the squares cut one after
    /// another from golden rectangles, with the squares' sides drawn too.
    /// Built in a unit golden rectangle, then fitted to `rect` and placed
    /// by `orientation` (as drawn, or mirrored one way or both).
    static func spiral(in rect: CGRect, orientation: Int) -> Path {
        var p = Path()
        // Unit rectangle phi × 1, the spiral winding into the right.
        var box = CGRect(x: 0, y: 0, width: phi, height: 1)
        for step in 0..<9 {
            let side = min(box.width, box.height)
            let square: CGRect, centre: CGPoint, start: Angle
            switch step % 4 {
            case 0: // square on the left
                square = CGRect(x: box.minX, y: box.minY, width: side, height: side)
                centre = CGPoint(x: square.maxX, y: square.maxY); start = .degrees(180)
                box = CGRect(x: square.maxX, y: box.minY, width: box.width - side, height: box.height)
            case 1: // on top
                square = CGRect(x: box.minX, y: box.minY, width: side, height: side)
                centre = CGPoint(x: square.minX, y: square.maxY); start = .degrees(270)
                box = CGRect(x: box.minX, y: square.maxY, width: box.width, height: box.height - side)
            case 2: // on the right
                square = CGRect(x: box.maxX - side, y: box.minY, width: side, height: side)
                centre = CGPoint(x: square.minX, y: square.minY); start = .degrees(0)
                box = CGRect(x: box.minX, y: box.minY, width: box.width - side, height: box.height)
            default: // at the bottom
                square = CGRect(x: box.minX, y: box.maxY - side, width: side, height: side)
                centre = CGPoint(x: square.maxX, y: square.minY); start = .degrees(90)
                box = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height - side)
            }
            p.addRect(square)
            p.move(to: CGPoint(x: centre.x + side * cos(start.radians), y: centre.y + side * sin(start.radians)))
            p.addArc(center: centre, radius: side, startAngle: start, endAngle: start + .degrees(90), clockwise: false)
        }
        // Place it: on its side for a tall rectangle, so it is never
        // squashed, then mirrored left-right, both ways or top-bottom by
        // `orientation`, then stretched over `rect`.
        var t = CGAffineTransform.identity
        var size = CGSize(width: phi, height: 1)
        if rect.height > rect.width {
            t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
            size = CGSize(width: 1, height: phi)
        }
        let o = orientation % 4
        if o == 1 || o == 2 { t = t.concatenating(CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)) }
        if o == 2 || o == 3 { t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)) }
        t = t.concatenating(CGAffineTransform(scaleX: rect.width / size.width, y: rect.height / size.height))
        t = t.concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY))
        return p.applying(t)
    }
}

/// The crop tool's view settings, kept between launches like Lightroom's.
enum CropToolPreferences {
    static let guideKey = "latent.cropGuide"
    static let orientationKey = "latent.cropGuideOrientation"
    static let maskOpacityKey = "latent.cropMaskOpacity"
    static let defaultMaskOpacity = 0.55

    static var guide: CropGuide {
        get { UserDefaults.standard.string(forKey: guideKey).flatMap(CropGuide.init(rawValue:)) ?? .thirds }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: guideKey) }
    }

    /// O: the next overlay.
    static func cycleGuide() {
        guide = guide.next
        UserDefaults.standard.set(0, forKey: orientationKey)
    }

    /// ⇧O: the overlay's next orientation.
    static func rotateGuide() {
        let n = guide.orientations
        guard n > 1 else { return }
        let now = UserDefaults.standard.integer(forKey: orientationKey)
        UserDefaults.standard.set((now + 1) % n, forKey: orientationKey)
    }
}
