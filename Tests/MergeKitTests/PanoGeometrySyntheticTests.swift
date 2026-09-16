import XCTest
import simd
@testable import MergeKit

/// The panorama geometry on synthetic photos with known cameras: frames
/// rendered from an analytic scene through `PanoramaMath`, as a handheld
/// sweep would take them (yaw steps, small pitch and roll wobble, 25-40%
/// overlap, different exposures and an EXIF focal length that is off).
final class PanoGeometrySyntheticTests: XCTestCase {
    // MARK: - The scene

    /// A deterministic hash of a lattice point, 0...1.
    static func hash(_ x: Int, _ y: Int, _ seed: Int) -> Float {
        var h = UInt64(bitPattern: Int64(x &* 73_856_093 ^ y &* 19_349_663 ^ seed &* 83_492_791))
        h = (h ^ (h >> 33)) &* 0xFF51_AFD7_ED55_8CCD
        h = (h ^ (h >> 33)) &* 0xC4CE_B9FE_1A85_EC53
        return Float((h ^ (h >> 33)) & 0xFFFF) / 65535
    }

    /// Smooth value noise at (u, v) lattice units.
    static func noise(_ u: Double, _ v: Double, _ seed: Int) -> Float {
        let iu = Int(u.rounded(.down)), iv = Int(v.rounded(.down))
        func smooth(_ t: Double) -> Float { Float(t * t * (3 - 2 * t)) }
        let fu = smooth(u - Double(iu)), fv = smooth(v - Double(iv))
        let a = hash(iu, iv, seed), b = hash(iu + 1, iv, seed), c = hash(iu, iv + 1, seed), d = hash(iu + 1, iv + 1, seed)
        return (a * (1 - fu) + b * fu) * (1 - fv) + (c * (1 - fu) + d * fu) * fv
    }

    /// Scene radiance (camera RGB) in a world direction: a sky gradient
    /// above the horizon and textured "land" below, with detail at several
    /// scales everywhere so both ECC and corners have something to hold.
    static func radiance(_ d: SIMD3<Double>) -> SIMD3<Float> {
        let longitude = atan2(d.x, d.z), latitude = atan2(-d.y, (d.x * d.x + d.z * d.z).squareRoot())
        // Lattice in radians: cells of 1/50, 1/100 and 1/200 rad (16, 8 and 4
        // thumbnail texels at the tests' 800 px/rad).
        let u = longitude * 50, v = latitude * 50
        let detail = 0.55 * noise(u, v, 1) + 0.3 * noise(2 * u, 2 * v, 2) + 0.15 * noise(4 * u, 4 * v, 3)
        let sky = latitude > 0.05
        let base: Float = sky ? 0.25 + 0.2 * Float(min(latitude, 0.5)) : 0.06
        let contrast: Float = sky ? 0.6 : 2.4
        let luminance = base * pow(2, contrast * (detail - 0.5))
        let tint = SIMD3<Float>(0.9 + 0.2 * noise(u * 0.5, v * 0.5, 4), 1, 0.9 + 0.3 * noise(u * 0.5, v * 0.5, 5))
        return luminance * tint
    }

    // MARK: - Frames

    struct TrueCamera {
        let yaw: Double, pitch: Double, roll: Double
        /// Light gathered, relative (the pixels are radiance x exposure).
        let exposure: Double

        var rotation: simd_double3x3 {
            let d = Double.pi / 180
            let (y, p, r) = (yaw * d, pitch * d, roll * d)
            // Yaw about the vertical, then pitch up, then roll clockwise, in
            // the panorama's axes (+y down).
            let rotY = simd_double3x3(rows: [SIMD3(cos(y), 0, sin(y)), SIMD3(0, 1, 0), SIMD3(-sin(y), 0, cos(y))])
            let rotX = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(p), -sin(p)), SIMD3(0, sin(p), cos(p))])
            let rotZ = simd_double3x3(rows: [SIMD3(cos(r), -sin(r), 0), SIMD3(sin(r), cos(r), 0), SIMD3(0, 0, 1)])
            return rotY * rotX * rotZ
        }
    }

    static let span = 8
    /// Full-resolution portrait photos, 3000 x 4400 px, focal length 6400 px
    /// (26° across): thumbnails of 375 x 550 texels at 800 px/rad.
    static let width = 3000, height = 4400
    static let focal = 6400.0

    /// Renders one thumbnail of the scene.
    static func frame(_ camera: TrueCamera, index: Int, exifExposure: Double, exifFocal: Double,
                      tilt: simd_double3x3 = matrix_identity_double3x3) -> PanoramaFrameInput {
        let tw = width / span, th = height / span
        let placed = PanoramaCamera(frameIndex: index, rotation: PanoramaRotation.rowMajor(tilt * camera.rotation),
                                    focalLengthPixels: focal, principalPoint: SIMD2(Double(width), Double(height)) / 2,
                                    width: width, height: height, exposureGain: 1)
        var rgba = [Float](repeating: 1, count: tw * th * 4)
        for j in 0..<th {
            for i in 0..<tw {
                // The mean of four samples inside the texel: a little of the
                // area averaging a real reduction does.
                var sum = SIMD3<Float>.zero
                for (ox, oy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                    let p = SIMD2((Double(i) + ox) * Double(span), (Double(j) + oy) * Double(span))
                    sum += radiance(PanoramaMath.direction(framePixel: p, camera: placed))
                }
                let value = sum * Float(0.25 * camera.exposure)
                let k = 4 * (j * tw + i)
                rgba[k] = value.x; rgba[k + 1] = value.y; rgba[k + 2] = value.z
            }
        }
        // EXIF: shutter 1/100 s at ISO 100, the aperture giving `exifExposure`.
        let aperture = (0.01 * 100 / exifExposure).squareRoot()
        let diagonal = (Double(width * width + height * height)).squareRoot()
        let metadata = PanoramaFrameMetadata(
            name: "synthetic-\(index)", captureTime: Date(timeIntervalSince1970: 1_000 + Double(index)),
            width: width, height: height,
            focalLengthMillimetres: exifFocal * PanoramaFrameMetadata.fullFrameDiagonalMillimetres / diagonal,
            cropFactor: 1, exposureTime: 0.01, iso: 100, aperture: aperture)
        let thumbnail = PanoramaThumbnail(width: tw, height: th, span: span, rgba: rgba,
                                          clippedShare: [Float](repeating: 0, count: tw * th))
        return PanoramaFrameInput(metadata: metadata, thumbnail: thumbnail)
    }

    /// A seven-frame sweep: steps of 16-19.5° (25-38% overlap), pitch about
    /// 4° up with a degree of wobble, roll within a degree, exposures over
    /// about 1.3 stops, EXIF focal length 2% long, and one photo whose EXIF
    /// exposure is 0.15 stops wrong.
    static let sweep: [TrueCamera] = [
        TrueCamera(yaw: -52, pitch: 4.5, roll: 0.6, exposure: 1.0),
        TrueCamera(yaw: -35, pitch: 3.2, roll: -0.8, exposure: 1.4),
        TrueCamera(yaw: -17, pitch: 4.9, roll: 0.2, exposure: 0.7),
        TrueCamera(yaw: 2.5, pitch: 3.6, roll: 0.9, exposure: 1.0),
        TrueCamera(yaw: 19, pitch: 4.1, roll: -0.4, exposure: 1.8),
        TrueCamera(yaw: 36, pitch: 3.0, roll: 0.3, exposure: 1.2),
        TrueCamera(yaw: 53, pitch: 4.4, roll: -0.7, exposure: 0.9),
    ]
    static let wrongExif = 4

    nonisolated(unsafe) static var cached: (inputs: [PanoramaFrameInput], result: PanoramaLayoutResult)?
    static let lock = NSLock()

    static func solvedSweep() throws -> (inputs: [PanoramaFrameInput], result: PanoramaLayoutResult) {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let inputs = sweep.enumerated().map { index, camera in
            frame(camera, index: index, exifExposure: camera.exposure * (index == wrongExif ? pow(2, 0.15) : 1),
                  exifFocal: focal * 1.02)
        }
        let result = try PanoramaLayoutSolver().solve(inputs)
        cached = (inputs, result)
        return (inputs, result)
    }

    // MARK: - Tests

    func testRecoversRotationsFocalLengthAndGains() throws {
        let (_, result) = try Self.solvedSweep()
        let layout = result.layout, report = result.report
        for pair in report.pairs {
            print("pano-synthetic | pair \(pair.first)-\(pair.second) \(pair.method?.rawValue ?? "-") "
                  + String(format: "NCC %.4f overlap %.2f inliers %d/%d", pair.ncc, pair.overlap, pair.inliers, pair.matches)
                  + (pair.note.map { " (\($0))" } ?? ""))
        }
        XCTAssertEqual(layout.cameras.count, Self.sweep.count, "every frame connected")
        XCTAssertTrue(report.leftOut.isEmpty)

        // The layout is levelled and centred, so it differs from the truth
        // by one rotation of the whole panorama: fit it, then compare.
        var from: [SIMD3<Double>] = [], to: [SIMD3<Double>] = []
        for camera in layout.cameras {
            let truth = Self.sweep[camera.frameIndex].rotation, solved = camera.rotationMatrix
            for axis in [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)] {
                from.append(truth * axis)
                to.append(solved * axis)
            }
        }
        let global = PanoramaRotation.fit(from: from, to: to)
        var worst = 0.0
        for camera in layout.cameras {
            let error = PanoramaRotation.angle(between: global * Self.sweep[camera.frameIndex].rotation,
                                               and: camera.rotationMatrix) * 180 / .pi
            worst = max(worst, error)
        }
        let focalError = abs(report.focalLengthPixels / Self.focal - 1)
        print(String(format: "pano-synthetic | worst rotation error %.4f deg, focal %.1f px (%.3f%% off, EXIF %.1f), RMS %.2f px",
                     worst, report.focalLengthPixels, focalError * 100, report.exifFocalLengthPixels, report.rmsErrorPixels))
        XCTAssertLessThan(worst, 0.05, "rotations within 0.05°")
        XCTAssertLessThan(focalError, 0.005, "focal length within 0.5%")

        // Gains: multiplying each frame's pixels by its gain must make them
        // agree, up to the panorama's overall brightness.
        let truths = layout.cameras.map { 1 / Self.sweep[$0.frameIndex].exposure }
        let gains = layout.cameras.map(\.exposureGain)
        let logRatios: [Double] = zip(gains, truths).map { log($0 / $1) }
        let scale = exp(logRatios.reduce(0, +) / Double(gains.count))
        for (k, camera) in layout.cameras.enumerated() {
            let error = abs(gains[k] / (truths[k] * scale) - 1)
            print(String(format: "pano-synthetic | frame %d gain %.4f, truth %.4f, error %.3f%%, EXIF gain %.4f",
                         camera.frameIndex, gains[k], truths[k] * scale, error * 100,
                         report.frames[camera.frameIndex].exifGain))
            XCTAssertLessThan(error, 0.01, "gain of frame \(camera.frameIndex) within 1%")
        }
    }

    func testChoosesCylindricalLevelledAndCentred() throws {
        let (_, result) = try Self.solvedSweep()
        let layout = result.layout
        // About 105° of yaw plus a frame: too wide for Perspective.
        XCTAssertEqual(layout.canvas.projection, .cylindrical)
        XCTAssertEqual(layout.canvas.pixelsPerRadian, result.report.focalLengthPixels, accuracy: 1e-9)
        let angles = layout.cameras.map { PanoramaRotation.yawPitchRoll($0.rotationMatrix) }
        // Capture order runs left to right.
        for k in 1..<angles.count { XCTAssertGreaterThan(angles[k].yaw, angles[k - 1].yaw) }
        // Centred: the first and last photos' yaws balance.
        XCTAssertEqual(angles.first!.yaw + angles.last!.yaw, 0, accuracy: 0.5)
        // Level: the true pitches and rolls come back within the wobble the
        // levelling can't know was deliberate (well under a degree).
        for (k, a) in angles.enumerated() {
            XCTAssertEqual(a.pitch, Self.sweep[k].pitch, accuracy: 0.5, "pitch of frame \(k)")
            XCTAssertEqual(a.roll, Self.sweep[k].roll, accuracy: 0.5, "roll of frame \(k)")
        }
        // The canvas holds every photo's outline and not much more.
        let extent = PanoramaCanvasBuilder.extent(layout.cameras)
        XCTAssertEqual(Double(layout.canvas.width), extent.widthDegrees * .pi / 180 * layout.canvas.pixelsPerRadian,
                       accuracy: 3)
    }

    func testAutoCropIsCoveredEverywhere() throws {
        let (inputs, result) = try Self.solvedSweep()
        let layout = result.layout
        let crop = layout.autoCropRect
        XCTAssertGreaterThan(crop.width * crop.height, 0.5 * Double(layout.canvas.width * layout.canvas.height))
        // Every point of the rectangle (on a fine grid, edges included) lands
        // inside some photo.
        var outside = 0
        for j in 0...40 {
            for i in 0...200 {
                let p = SIMD2<Double>(Double(crop.minX) + Double(crop.width) * Double(i) / 200,
                                      Double(crop.minY) + Double(crop.height) * Double(j) / 40)
                let d = try XCTUnwrap(PanoramaMath.direction(canvasPixel: p, canvas: layout.canvas))
                let covered = layout.cameras.contains { camera in
                    guard let q = PanoramaMath.framePixel(direction: d, camera: camera) else { return false }
                    return q.x >= -0.5 && q.y >= -0.5 && q.x <= Double(camera.width) + 0.5
                        && q.y <= Double(camera.height) + 0.5
                }
                if !covered { outside += 1 }
            }
        }
        XCTAssertEqual(outside, 0, "the Auto Crop rectangle must be covered throughout")
        // And it is the largest: one coarse cell more in any direction isn't.
        let cell = Double(max(layout.canvas.width, layout.canvas.height)) / 1024
        for rect in [crop.insetBy(dx: 0, dy: -2 * cell), crop.insetBy(dx: -2 * cell, dy: 0)] {
            var uncovered = false
            for j in 0...40 where !uncovered {
                for i in 0...200 {
                    let p = SIMD2<Double>(Double(rect.minX) + Double(rect.width) * Double(i) / 200,
                                          Double(rect.minY) + Double(rect.height) * Double(j) / 40)
                    guard let d = PanoramaMath.direction(canvasPixel: p, canvas: layout.canvas) else { continue }
                    let covered = layout.cameras.contains { camera in
                        guard let q = PanoramaMath.framePixel(direction: d, camera: camera) else { return false }
                        return q.x >= 0 && q.y >= 0 && q.x <= Double(camera.width) && q.y <= Double(camera.height)
                    }
                    if !covered { uncovered = true; break }
                }
            }
            XCTAssertTrue(uncovered, "a taller rectangle must leave the covered area")
        }
        _ = inputs
    }

    // MARK: - The two halves

    /// `solve` is `solveCameras` then `project`, and the two together give
    /// exactly what the one gave: the split is a seam, not a change.
    func testSolvingInTwoStepsGivesTheSameLayout() throws {
        let (inputs, whole) = try Self.solvedSweep()
        let solver = PanoramaLayoutSolver()
        let split = try solver.project(solver.solveCameras(inputs))
        XCTAssertEqual(split.layout, whole.layout)
        XCTAssertEqual(split.report.leftOut, whole.report.leftOut)
        XCTAssertEqual(split.report.focalLengthPixels, whole.report.focalLengthPixels)
        XCTAssertEqual(split.report.rmsErrorPixels, whole.report.rmsErrorPixels)
        XCTAssertEqual(split.report.frames, whole.report.frames)
        XCTAssertEqual(split.report.widthDegrees, whole.report.widthDegrees)
    }

    /// The point of the split: the projection reaches the canvas and the
    /// crop and nothing before them, so the dialog's picker can project the
    /// cameras it already has instead of registering the photos again.
    ///
    /// Each projection is also what running the whole thing that way would
    /// have given, so nothing is lost by reusing the cameras.
    func testProjectingAgainCostsAFractionAndMatchesAFullSolve() throws {
        let (inputs, _) = try Self.solvedSweep()
        let clock = ContinuousClock()
        let cameraStart = clock.now
        let solved = try PanoramaLayoutSolver().solveCameras(inputs)
        let cameraSeconds = Self.seconds(clock.now - cameraStart)

        var projectSeconds = 0.0
        for projection in [PanoramaProjection.cylindrical, .spherical, .perspective] {
            let solver = PanoramaLayoutSolver(options: PanoramaLayoutOptions(projection: projection))
            let start = clock.now
            let again = try solver.project(solved)
            projectSeconds += Self.seconds(clock.now - start)
            XCTAssertEqual(again.layout.canvas.projection, projection)
            // The same as measuring the photos all over again with it.
            let fromScratch = try solver.solve(inputs)
            XCTAssertEqual(again.layout, fromScratch.layout, "\(projection)")
        }
        let each = projectSeconds / 3
        print(String(format: "pano-synthetic | cameras %.3f s, projection %.4f s each (%.1fx cheaper)",
                     cameraSeconds, each, cameraSeconds / max(each, 1e-9)))
        XCTAssertLessThan(each, cameraSeconds / 4,
                          "a new projection must be far cheaper than solving the cameras again")
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }

    /// Cancelling the task stops the solve where it is. Without a check
    /// anywhere inside it, a dialog closed with Cancel — or a projection
    /// changed — left the whole registration and camera solve running to
    /// the end, on the same GPU as the analysis that replaced it.
    func testACancelledSolveStopsInsteadOfRunningToTheEnd() async throws {
        let inputs = Self.sweep.enumerated().map { index, camera in
            Self.frame(camera, index: index, exifExposure: camera.exposure, exifFocal: Self.focal)
        }
        let clock = ContinuousClock()
        let wholeStart = clock.now
        _ = try PanoramaLayoutSolver().solve(inputs)
        let wholeSeconds = Self.seconds(clock.now - wholeStart)

        let task = Task.detached(priority: .userInitiated) { try PanoramaLayoutSolver().solve(inputs) }
        task.cancel()
        let cancelledStart = clock.now
        do {
            _ = try await task.value
            XCTFail("a cancelled solve must give up, not finish")
        } catch is CancellationError {
        } catch {
            XCTFail("\(error)")
        }
        let cancelledSeconds = Self.seconds(clock.now - cancelledStart)
        print(String(format: "pano-synthetic | solve %.3f s, cancelled after %.4f s", wholeSeconds, cancelledSeconds))
        XCTAssertLessThan(cancelledSeconds, wholeSeconds / 2, "it gave up at the first check, not at the end")
    }

    func testNarrowSweepIsPerspectiveAndABracketIsRefused() throws {
        // Three frames 15° apart: about 56° across, so Perspective.
        let narrow = [-15.0, 0, 15].enumerated().map { k, yaw in
            Self.frame(TrueCamera(yaw: yaw, pitch: 2, roll: 0, exposure: 1), index: k, exifExposure: 1,
                       exifFocal: Self.focal)
        }
        let result = try PanoramaLayoutSolver().solve(narrow)
        XCTAssertEqual(result.layout.canvas.projection, .perspective)
        XCTAssertEqual(result.layout.cameras.count, 3)

        // The same view three times at different exposures: an HDR bracket.
        let bracket = [0.25, 1, 4].enumerated().map { k, exposure in
            Self.frame(TrueCamera(yaw: 0.05 * Double(k), pitch: 2, roll: 0, exposure: exposure), index: k,
                       exifExposure: exposure, exifFocal: Self.focal)
        }
        XCTAssertThrowsError(try PanoramaLayoutSolver().solve(bracket)) { error in
            guard case PanoramaError.notAPanorama(let reason) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(reason.contains("same view"), reason)
        }
    }

    func testCornerMatchingFindsTheRotationWithoutAGuess() throws {
        let a = Self.frame(TrueCamera(yaw: 0, pitch: 3, roll: 0.5, exposure: 1), index: 0, exifExposure: 1,
                           exifFocal: Self.focal)
        let b = Self.frame(TrueCamera(yaw: 18, pitch: 2, roll: -0.5, exposure: 2), index: 1, exifExposure: 2,
                           exifFocal: Self.focal)
        let fa = PanoramaFeatures.detect(a.thumbnail, gain: 1), fb = PanoramaFeatures.detect(b.thumbnail, gain: 2)
        let matches = PanoramaFeatures.match(fa, fb)
        let centre = SIMD2(Double(Self.width), Double(Self.height)) / 2
        let fit = try XCTUnwrap(PanoramaFeatures.fitRotation(
            pointsA: matches.map { fa.points[$0.0] }, pointsB: matches.map { fb.points[$0.1] }, focal: Self.focal,
            centreA: centre, centreB: centre, tolerance: 20))
        let truth = TrueCamera(yaw: 18, pitch: 2, roll: -0.5, exposure: 2).rotation.transpose
            * TrueCamera(yaw: 0, pitch: 3, roll: 0.5, exposure: 1).rotation
        let error = PanoramaRotation.angle(between: fit.rotation, and: truth) * 180 / .pi
        print(String(format: "pano-synthetic | corners: %d and %d found, %d matched, %d agree, rotation off %.3f deg, RMS %.2f px",
                     fa.count, fb.count, matches.count, fit.inliers.count, error, fit.rmsError))
        XCTAssertGreaterThan(fit.inliers.count, 40)
        XCTAssertGreaterThan(Double(fit.inliers.count), 0.5 * Double(matches.count))
        // Corners sit on whole texels (8 px), so this is coarser than ECC.
        XCTAssertLessThan(error, 0.1)
    }
}
