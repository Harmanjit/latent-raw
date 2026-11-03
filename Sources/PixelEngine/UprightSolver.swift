import Foundation
import simd

/// Turns straight lines found in a picture (or drawn by the user) into
/// the perspective correction that makes them level and plumb.
///
/// Everything here works in `PerspectiveSpace`, centred and measured in
/// half short sides, with y pointing down. Lines within 30° of vertical
/// form the vertical family, within 30° of horizontal the horizontal one.
/// A family whose lines meet at a vanishing point gets that point sent to
/// infinity by the projective part of the homography (the third row,
/// chosen as small as possible so the picture is disturbed least); an
/// affine part then turns the families onto the axes. The result keeps
/// the centre where it was and roughly the area it had.
public enum UprightSolver {
    /// Lines this close to an axis (degrees) count towards levelling.
    static let levelTolerance: Float = 15
    /// Lines this close to an axis (degrees) join that axis's family.
    static let familyTolerance: Float = 30
    /// A segment agrees with a vanishing point when the direction to it
    /// from the segment's midpoint is within this many degrees.
    static let inlierDegrees: Float = 1.5

    // MARK: - Levelling

    /// How far a segment is from the nearest of horizontal (`vertical`
    /// false) or vertical, in degrees, with its sign: the picture needs
    /// turning by minus this to level it.
    static func deviation(_ s: LineSegment, vertical: Bool) -> Float {
        let a = s.angle
        guard vertical else { return a }
        return a > 0 ? a - 90 : a + 90
    }

    static func family(_ lines: [LineSegment], vertical: Bool, tolerance: Float) -> [LineSegment] {
        lines.filter { abs(deviation($0, vertical: vertical)) <= tolerance }
    }

    /// The tilt most of the lines agree on, in degrees, or nil when there
    /// isn't enough to go on. A length-weighted histogram finds the
    /// consensus (one stray diagonal must not pull it), then the lines
    /// near the peak are averaged for precision.
    static func consensusDeviation(_ lines: [LineSegment], vertical: [Bool], tolerance: Float,
                                   minimumWeight: Float) -> Float? {
        let binWidth: Float = 0.1
        let bins = Int((2 * tolerance / binWidth).rounded()) + 1
        var histogram = [Float](repeating: 0, count: bins)
        var samples: [(d: Float, w: Float)] = []
        for (s, v) in zip(lines, vertical) {
            let d = deviation(s, vertical: v)
            guard abs(d) <= tolerance else { continue }
            let w = s.length
            samples.append((d, w))
            let centre = Int(((d + tolerance) / binWidth).rounded())
            // A triangle five bins either side, so near-equal angles pile up.
            for k in -5...5 {
                let b = centre + k
                guard b >= 0, b < bins else { continue }
                histogram[b] += w * (1 - Float(abs(k)) / 6)
            }
        }
        let total = samples.reduce(0) { $0 + $1.w }
        guard total >= minimumWeight, let peak = histogram.indices.max(by: { histogram[$0] < histogram[$1] })
        else { return nil }
        let peakAngle = Float(peak) * binWidth - tolerance
        let near = samples.filter { abs($0.d - peakAngle) <= 0.75 }
        let weight = near.reduce(0) { $0 + $1.w }
        guard weight > 0 else { return peakAngle }
        return near.reduce(0) { $0 + $1.d * $1.w } / weight
    }

    /// The straighten angle (degrees, positive clockwise, as the crop's)
    /// that levels the picture, from horizontal and vertical lines alike:
    /// Auto in the crop tool. Nil when the picture has too few lines.
    public static func autoStraightenAngle(_ lines: [LineSegment]) -> Float? {
        var used: [LineSegment] = [], vertical: [Bool] = []
        for s in lines {
            if abs(deviation(s, vertical: false)) <= levelTolerance { used.append(s); vertical.append(false) }
            else if abs(deviation(s, vertical: true)) <= levelTolerance { used.append(s); vertical.append(true) }
        }
        guard let d = consensusDeviation(used, vertical: vertical, tolerance: levelTolerance,
                                         minimumWeight: 0.2) else { return nil }
        return -d
    }

    /// The angle a single drawn line asks for: whichever of level or
    /// plumb is nearer. Degrees, positive clockwise.
    public static func straightenAngle(for line: LineSegment) -> Float {
        let d = deviation(line, vertical: abs(line.angle) > 45)
        return -d
    }

    // MARK: - Vanishing points

    /// Where the lines of a family meet, as a homogeneous point (z near 0
    /// when they are parallel), found by RANSAC over pairs and refined by
    /// least squares on the lines that agree. Nil when fewer than two
    /// separate lines agree.
    static func vanishingPoint(_ lines: [LineSegment], minimumSpread: Float = 0.05) -> SIMD3<Float>? {
        let usable = Array(lines.sorted { $0.length > $1.length }.prefix(60))
        guard usable.count >= 2 else { return nil }
        let homogeneous = usable.map(\.homogeneous)
        var best: (score: Float, inliers: [Int])?
        // Every pair of the longest lines, which is few enough to try all.
        let tried = min(usable.count, 24)
        for i in 0..<tried {
            for j in (i + 1)..<tried {
                var v = simd_cross(homogeneous[i], homogeneous[j])
                guard simd_length(v) > 1e-6 else { continue }
                v = simd_normalize(v)
                // Two pieces of the same edge say nothing about where it goes.
                guard separation(usable[i], usable[j]) >= minimumSpread else { continue }
                var score: Float = 0, inliers: [Int] = []
                for (k, s) in usable.enumerated() where agrees(s, with: v) {
                    score += s.length
                    inliers.append(k)
                }
                if score > (best?.score ?? 0) { best = (score, inliers) }
            }
        }
        guard let best, best.inliers.count >= 2 else { return nil }
        let chosen = best.inliers.map { usable[$0] }
        return refinedVanishingPoint(chosen) ?? {
            let v = simd_cross(chosen[0].homogeneous, chosen[1].homogeneous)
            return simd_length(v) > 0 ? simd_normalize(v) : nil
        }()
    }

    /// The point meeting `lines` best in the least-squares sense: the
    /// eigenvector of Σ w·l·lᵀ with the smallest eigenvalue.
    static func refinedVanishingPoint(_ lines: [LineSegment]) -> SIMD3<Float>? {
        var a = simd_float3x3()
        for s in lines {
            let l = s.homogeneous
            a += s.length * simd_float3x3(columns: (l * l.x, l * l.y, l * l.z))
        }
        guard let v = smallestEigenvector(a), simd_length(v) > 0 else { return nil }
        return simd_normalize(v)
    }

    /// How far apart two segments' lines are, measured at the second
    /// segment's midpoint from the first segment's line.
    static func separation(_ a: LineSegment, _ b: LineSegment) -> Float {
        abs(simd_dot(a.homogeneous, SIMD3(b.midpoint.x, b.midpoint.y, 1)))
    }

    static func agrees(_ s: LineSegment, with v: SIMD3<Float>) -> Bool {
        let m = s.midpoint
        // Direction from the midpoint towards the point (or along it, at infinity).
        let towards = abs(v.z) < 1e-6 ? SIMD2(v.x, v.y) : SIMD2(v.x / v.z, v.y / v.z) - m
        guard simd_length(towards) > 1e-6 else { return true }
        let d = simd_normalize(s.b - s.a), t = simd_normalize(towards)
        let sine = abs(d.x * t.y - d.y * t.x)
        return sine <= sin(inlierDegrees * .pi / 180)
    }

    /// Jacobi rotations on a symmetric 3×3: plenty for a vanishing point.
    static func smallestEigenvector(_ m: simd_float3x3) -> SIMD3<Float>? {
        var a = [[Double]](repeating: [0, 0, 0], count: 3)
        for c in 0..<3 { for r in 0..<3 { a[r][c] = Double(m[c][r]) } }
        var v: [[Double]] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
        for _ in 0..<50 {
            var p = 0, q = 1
            var largest = abs(a[0][1])
            if abs(a[0][2]) > largest { largest = abs(a[0][2]); p = 0; q = 2 }
            if abs(a[1][2]) > largest { largest = abs(a[1][2]); p = 1; q = 2 }
            if largest < 1e-14 { break }
            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot(), s = t * c
            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }
        let i = (0..<3).min { a[$0][$0] < a[$1][$1] }!
        let out = SIMD3(Float(v[0][i]), Float(v[1][i]), Float(v[2][i]))
        return out.x.isFinite && out.y.isFinite && out.z.isFinite ? out : nil
    }

    // MARK: - Solving

    /// How strongly each mode may tilt the picture: the length of the
    /// projective row. Auto holds back so a strong convergence is eased
    /// rather than forced, which tends to look natural.
    static func maximumTilt(for mode: UprightCorrection.Mode) -> Float {
        switch mode {
        case .auto: 0.3
        case .level: 0
        case .vertical, .full: 0.7
        case .guided: 0.9
        }
    }

    /// The forward homography (source to output, in `PerspectiveSpace`)
    /// that `mode` asks for, from lines found in the picture; nil when
    /// they don't support it. `corners` bounds the picture, so the result
    /// never folds it over.
    public static func solve(_ mode: UprightCorrection.Mode, lines: [LineSegment],
                             corners: [SIMD2<Float>]) -> simd_float3x3? {
        let verticals = family(lines, vertical: true, tolerance: familyTolerance)
        let horizontals = family(lines, vertical: false, tolerance: familyTolerance)
        switch mode {
        case .level:
            let flat = family(lines, vertical: false, tolerance: levelTolerance)
            let plumb = family(lines, vertical: true, tolerance: levelTolerance)
            let d = consensusDeviation(flat, vertical: flat.map { _ in false }, tolerance: levelTolerance,
                                       minimumWeight: 0.2)
                ?? consensusDeviation(plumb, vertical: plumb.map { _ in true }, tolerance: levelTolerance,
                                      minimumWeight: 0.2)
            guard let d else { return nil }
            return rotation(degrees: -d)
        case .auto, .vertical:
            guard let vp = vanishingPoint(verticals) ?? parallelDirection(verticals, vertical: true) else {
                // No verticals to straighten: Auto still levels.
                return mode == .auto ? solve(.level, lines: lines, corners: corners) : nil
            }
            return build(verticalVP: vp, horizontalVP: nil, verticalLines: verticals, horizontalLines: [],
                         maximumTilt: maximumTilt(for: mode), corners: corners)
        case .full:
            let vv = vanishingPoint(verticals) ?? parallelDirection(verticals, vertical: true)
            let hv = vanishingPoint(horizontals) ?? parallelDirection(horizontals, vertical: false)
            guard vv != nil || hv != nil else { return nil }
            return build(verticalVP: vv, horizontalVP: hv, verticalLines: verticals, horizontalLines: horizontals,
                         maximumTilt: maximumTilt(for: mode), corners: corners)
        case .guided:
            return solveGuided(lines, corners: corners)
        }
    }

    /// Guided Upright: each drawn line is plumb or level by its own angle.
    /// Two or more in a family fix its vanishing point; one fixes only its
    /// direction.
    public static func solveGuided(_ guides: [LineSegment], corners: [SIMD2<Float>]) -> simd_float3x3? {
        let usable = guides.filter { $0.length > 1e-3 }
        guard !usable.isEmpty else { return nil }
        let verticals = usable.filter { abs($0.angle) > 45 }
        let horizontals = usable.filter { abs($0.angle) <= 45 }
        func point(_ family: [LineSegment], vertical: Bool) -> SIMD3<Float>? {
            switch family.count {
            case 0: return nil
            case 1:
                let d = family[0].b - family[0].a
                return simd_normalize(SIMD3(d.x, d.y, 0))
            case 2:
                let v = simd_cross(family[0].homogeneous, family[1].homogeneous)
                return simd_length(v) > 1e-9 ? simd_normalize(v) : parallelDirection(family, vertical: vertical)
            default:
                return refinedVanishingPoint(family)
            }
        }
        return build(verticalVP: point(verticals, vertical: true), horizontalVP: point(horizontals, vertical: false),
                     verticalLines: verticals, horizontalLines: horizontals,
                     maximumTilt: maximumTilt(for: .guided), corners: corners, minimumWeight: 0)
    }

    /// A family that is parallel already (or a single line): its point at
    /// infinity, from the consensus direction.
    static func parallelDirection(_ lines: [LineSegment], vertical: Bool) -> SIMD3<Float>? {
        guard let d = consensusDeviation(lines, vertical: lines.map { _ in vertical },
                                         tolerance: familyTolerance, minimumWeight: 0.2) else { return nil }
        let degrees = (vertical ? 90 : 0) + d
        let r = degrees * .pi / 180
        return SIMD3(cos(r), sin(r), 0)
    }

    static func rotation(degrees: Float) -> simd_float3x3 {
        let r = degrees * .pi / 180
        let c = cos(r), s = sin(r)
        return simd_float3x3(columns: (SIMD3(c, s, 0), SIMD3(-s, c, 0), SIMD3(0, 0, 1)))
    }

    /// The homography from up to two vanishing points: the projective row
    /// that sends them to infinity (limited to `maximumTilt` and so the
    /// picture never folds), then the affine part that turns the families
    /// onto the axes, then a scale that keeps the picture's area.
    static func build(verticalVP: SIMD3<Float>?, horizontalVP: SIMD3<Float>?,
                      verticalLines: [LineSegment], horizontalLines: [LineSegment],
                      maximumTilt: Float, corners: [SIMD2<Float>], minimumWeight: Float = 0.2) -> simd_float3x3? {
        // Projective row (a, b, 1): a·vx + b·vy + vz = 0 for each point.
        var ab = SIMD2<Float>(0, 0)
        switch (verticalVP, horizontalVP) {
        case let (v?, h?):
            let m = simd_float2x2(rows: [SIMD2(v.x, v.y), SIMD2(h.x, h.y)])
            if abs(m.determinant) > 1e-6 {
                ab = m.inverse * SIMD2(-v.z, -h.z)
            } else {
                ab = minimumNorm(v)
            }
        case let (v?, nil): ab = minimumNorm(v)
        case let (nil, h?): ab = minimumNorm(h)
        case (nil, nil): return nil
        }
        // Not more than the mode allows, and never so much that a corner
        // reaches the line at infinity.
        if simd_length(ab) > maximumTilt { ab *= maximumTilt / simd_length(ab) }
        let lowest = corners.map { simd_dot(ab, $0) }.min() ?? 0
        if 1 + lowest < 0.4 { ab *= 0.6 / -lowest }
        let projective = simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(ab.x, ab.y, 1)])

        // The families' directions after it, measured on the lines themselves.
        func direction(of lines: [LineSegment], point: SIMD3<Float>?, vertical: Bool) -> Float? {
            let moved = lines.map { $0.transformed(by: projective) }
            if let d = consensusDeviation(moved, vertical: moved.map { _ in vertical },
                                          tolerance: familyTolerance, minimumWeight: minimumWeight) {
                return d
            }
            // A drawn line or a direction alone: where the projective row sends the point.
            guard let point else { return nil }
            let q = projective * point
            let seg = LineSegment(.zero, abs(q.z) < 1e-6 ? SIMD2(q.x, q.y) : SIMD2(q.x, q.y) / q.z)
            guard seg.length > 0 else { return nil }
            let d = deviation(seg, vertical: vertical)
            return abs(d) <= 45 ? d : nil
        }
        let dv = direction(of: verticalLines, point: verticalVP, vertical: true)
        let dh = direction(of: horizontalLines, point: horizontalVP, vertical: false)

        var linear: simd_float3x3
        switch (dv, dh) {
        case let (v?, h?):
            // Columns: unit directions of the two families; its inverse
            // sends each onto its axis. Scaled back to unit determinant.
            let rv = (90 + v) * .pi / 180, rh = h * .pi / 180
            let m = simd_float2x2(columns: (SIMD2(cos(rh), sin(rh)), SIMD2(cos(rv), sin(rv))))
            guard m.determinant > 0.2 else { linear = rotation(degrees: -v); break }
            let l = m.inverse * m.determinant.squareRoot()
            linear = simd_float3x3(columns: (SIMD3(l.columns.0, 0), SIMD3(l.columns.1, 0), SIMD3(0, 0, 1)))
        case let (v?, nil): linear = rotation(degrees: -v)
        case let (nil, h?): linear = rotation(degrees: -h)
        case (nil, nil): linear = matrix_identity_float3x3
        }
        var forward = linear * projective
        // Keep the area the picture had, so the result is neither shrunk
        // into a corner nor blown up past the crop.
        let before = area(corners), after = area(corners.map { forward.applied(to: $0) })
        if before > 0, after > 0 {
            let k = (before / after).squareRoot()
            forward = simd_float3x3(diagonal: SIMD3(k, k, 1)) * forward
        }
        guard abs(forward.determinant) > 1e-6, forward.columns.0.x.isFinite else { return nil }
        return forward
    }

    static func minimumNorm(_ v: SIMD3<Float>) -> SIMD2<Float> {
        let n = v.x * v.x + v.y * v.y
        return n > 1e-12 ? -v.z * SIMD2(v.x, v.y) / n : .zero
    }

    /// Area of a polygon (shoelace), unsigned.
    static func area(_ p: [SIMD2<Float>]) -> Float {
        guard p.count >= 3 else { return 0 }
        var sum: Float = 0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}
