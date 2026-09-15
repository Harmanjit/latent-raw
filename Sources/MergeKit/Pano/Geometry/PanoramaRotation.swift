import Foundation
import simd

// Rotation maths the panorama geometry shares: turning a rotation into
// numbers and back, the rotation nearest a matrix, and the angles a report
// shows.

enum PanoramaRotation {
    /// The rotation by `angle` radians about the axis `omega / |omega|`,
    /// with `omega`'s length as the angle (Rodrigues' formula). The camera
    /// solve nudges each camera by one of these.
    static func exp(_ omega: SIMD3<Double>) -> simd_double3x3 {
        let angle = simd_length(omega)
        guard angle > 1e-12 else {
            // First order: I + [omega]x.
            return simd_double3x3(rows: [SIMD3(1, -omega.z, omega.y), SIMD3(omega.z, 1, -omega.x),
                                         SIMD3(-omega.y, omega.x, 1)])
        }
        return simd_double3x3(simd_quatd(angle: angle, axis: omega / angle))
    }

    /// The angle (radians) of the rotation taking `a` to `b`.
    static func angle(between a: simd_double3x3, and b: simd_double3x3) -> Double {
        let relative = a.transpose * b
        let trace = relative[0][0] + relative[1][1] + relative[2][2]
        return acos(min(1, max(-1, (trace - 1) / 2)))
    }

    /// The rotation nearest `m` (in the least-squares sense: the one
    /// maximising trace(Rᵀ m)), which is what "orthonormalised by SVD"
    /// gives, found with Horn's quaternion method instead.
    ///
    /// **Why not SVD.** The largest eigenvector of a 4 x 4 symmetric matrix
    /// built from `m` is the quaternion of that rotation. It needs only a
    /// small symmetric eigen-solver, gives a proper rotation (never a
    /// reflection) without a sign fix, and works when `m` is rank-deficient,
    /// as it is for two point pairs, the smallest sample RANSAC draws.
    static func nearest(to m: simd_double3x3) -> simd_double3x3 {
        // Horn writes S = Σ a bᵀ for rotating a onto b; here m = Σ b aᵀ,
        // so S is m transposed. simd indexes a matrix column first, so
        // S's row i, column j is m[i][j].
        func s(_ row: Int, _ column: Int) -> Double { m[row][column] }
        let (sxx, sxy, sxz) = (s(0, 0), s(0, 1), s(0, 2))
        let (syx, syy, syz) = (s(1, 0), s(1, 1), s(1, 2))
        let (szx, szy, szz) = (s(2, 0), s(2, 1), s(2, 2))
        let n: [[Double]] = [
            [sxx + syy + szz, syz - szy, szx - sxz, sxy - syx],
            [syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
            [szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
            [sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz],
        ]
        let (values, vectors) = symmetricEigen(n)
        let best = values.indices.max { values[$0] < values[$1] }!
        let q = vectors[best]
        let quaternion = simd_quatd(ix: q[1], iy: q[2], iz: q[3], r: q[0])
        guard quaternion.length > 1e-12 else { return matrix_identity_double3x3 }
        return simd_double3x3(quaternion.normalized)
    }

    /// The rotation R that best takes each `from` vector to its `to` vector
    /// (R·from ≈ to), weighted.
    static func fit(from: [SIMD3<Double>], to: [SIMD3<Double>], weights: [Double]? = nil) -> simd_double3x3 {
        var m = simd_double3x3()
        for k in from.indices {
            let w = weights?[k] ?? 1
            // Σ w · to · fromᵀ, the outer product added column by column.
            let a = from[k], b = to[k]
            m += simd_double3x3(columns: (b * (w * a.x), b * (w * a.y), b * (w * a.z)))
        }
        return nearest(to: m)
    }

    /// Eigenvalues and unit eigenvectors of a small symmetric matrix, by
    /// Jacobi rotations: exact to rounding for the 3 x 3 and 4 x 4 matrices
    /// used here, in a few sweeps. `vectors[k]` belongs to `values[k]`.
    static func symmetricEigen(_ matrix: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
        let n = matrix.count
        var a = matrix
        var v = (0..<n).map { i in (0..<n).map { j in i == j ? 1.0 : 0.0 } }
        for _ in 0..<60 {
            var off = 0.0
            for i in 0..<n { for j in (i + 1)..<n { off += a[i][j] * a[i][j] } }
            if off < 1e-30 { break }
            for p in 0..<n {
                for q in (p + 1)..<n where abs(a[p][q]) > 1e-300 {
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<n {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        let values = (0..<n).map { a[$0][$0] }
        let vectors = (0..<n).map { column in (0..<n).map { row in v[row][column] } }
        return (values, vectors)
    }

    /// A camera's direction as a report shows it, in degrees: yaw (right of
    /// the panorama's centre), pitch (above the horizon) and roll (the
    /// photo turned clockwise), for camera-to-world `r` in the panorama's
    /// axes (+y down).
    static func yawPitchRoll(_ r: simd_double3x3) -> (yaw: Double, pitch: Double, roll: Double) {
        let forward = r * SIMD3(0, 0, 1), right = r * SIMD3(1, 0, 0)
        let degrees = 180 / Double.pi
        let yaw = atan2(forward.x, forward.z)
        let pitch = atan2(-forward.y, (forward.x * forward.x + forward.z * forward.z).squareRoot())
        // The camera's right-hand axis dropping below the horizontal (+y) is
        // a clockwise turn, measured against the horizontal direction
        // square to where the camera looks.
        let level = simd_normalize(SIMD3(forward.z, 0, -forward.x))
        let roll = atan2(right.y, simd_dot(right, level))
        return (yaw * degrees, pitch * degrees, roll * degrees)
    }

    /// Row-major values of `r`, as `PanoramaCamera` stores them.
    static func rowMajor(_ r: simd_double3x3) -> [Double] {
        [r[0][0], r[1][0], r[2][0], r[0][1], r[1][1], r[2][1], r[0][2], r[1][2], r[2][2]]
    }
}
