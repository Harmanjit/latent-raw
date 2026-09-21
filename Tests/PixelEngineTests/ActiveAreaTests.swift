import XCTest
import Metal
@testable import PixelEngine
@testable import RawCore

/// The sensor plane is the camera's active area, not LibRaw's whole
/// readout: no masked border or padding reaches a render, and the Bayer
/// pattern the shaders read matches the plane's own (0, 0).
final class ActiveAreaTests: XCTestCase {

    /// The colour at (x, y) for a packed 2x2 pattern, second green folded
    /// onto green: `cfaColorRGB` in Shaders/Common.h.
    private func cfaColour(_ pattern: UInt8, x: Int, y: Int) -> Int {
        let index = ((y & 1) << 1) | (x & 1)
        let colour = Int(pattern >> (index * 2)) & 3
        return colour == 3 ? 1 : colour
    }

    // MARK: - Cutting the plane out of a readout

    /// A synthetic readout in LibRaw's terms: `pattern` counts from the
    /// active area's corner (as LibRaw's `filters` does), each active
    /// photosite holds 1000 x (its colour + 1) plus its readout index mod
    /// 1000, and the border holds 0xFFFF so any of it leaking through shows.
    private func readout(_ area: SensorActiveArea, pattern: UInt8) -> [UInt16] {
        var samples = [UInt16](repeating: 0xFFFF, count: area.fullWidth * area.fullHeight)
        for row in area.top..<(area.top + area.height) {
            for col in area.left..<(area.left + area.width) {
                let colour = cfaColour(pattern, x: col - area.left, y: row - area.top)
                let index = row * area.fullWidth + col
                samples[index] = UInt16(1000 * (colour + 1) + index % 1000)
            }
        }
        return samples
    }

    func testPlaneIsExactlyTheActiveAreaWithItsOwnBayerPhase() throws {
        let rggb: UInt8 = 0x94   // R G / G B at the active corner
        let cases: [(String, SensorActiveArea)] = [
            ("odd margins", SensorActiveArea(left: 3, top: 1, width: 16, height: 11, fullWidth: 23, fullHeight: 15)),
            ("even margins", SensorActiveArea(left: 4, top: 2, width: 16, height: 10, fullWidth: 22, fullHeight: 14)),
            ("odd left, even top", SensorActiveArea(left: 5, top: 2, width: 15, height: 9, fullWidth: 20, fullHeight: 11)),
            ("padding only", SensorActiveArea(left: 0, top: 0, width: 17, height: 12, fullWidth: 20, fullHeight: 13)),
        ]
        for (name, area) in cases {
            let samples = readout(area, pattern: rggb)
            let plane = try XCTUnwrap(samples.withUnsafeBufferPointer { SensorPlane(copying: area, of: $0) }, name)
            XCTAssertEqual(plane.count, area.width * area.height, name)
            let page = Int(getpagesize())
            XCTAssertEqual(Int(bitPattern: plane.pointer) % page, 0, name)

            let copied = Array(plane.samples)
            var phaseErrorsWithoutTheCut = 0
            for y in 0..<area.height {
                for x in 0..<area.width {
                    let value = Int(copied[y * area.width + x])
                    // The very photosite, not its neighbour...
                    XCTAssertEqual(value, Int(samples[(area.top + y) * area.fullWidth + area.left + x]), "\(name) (\(x), \(y))")
                    // ...whose colour is what the shaders will think it is.
                    XCTAssertEqual(value / 1000 - 1, cfaColour(rggb, x: x, y: y), "\(name) colour at (\(x), \(y))")
                    // The old whole-readout plane, read with the same pattern.
                    let old = Int(samples[y * area.fullWidth + x])
                    if old != 0xFFFF, old / 1000 - 1 != cfaColour(rggb, x: x, y: y) { phaseErrorsWithoutTheCut += 1 }
                }
            }
            // The test can tell: with an odd margin the uncut plane is out of phase.
            if area.left % 2 == 1 || area.top % 2 == 1 {
                XCTAssertGreaterThan(phaseErrorsWithoutTheCut, 0, name)
            }
        }
    }

    func testARectangleOutsideTheReadoutIsRefused() {
        let samples = [UInt16](repeating: 7, count: 20 * 10)
        let outside = [
            SensorActiveArea(left: 5, top: 0, width: 16, height: 10, fullWidth: 20, fullHeight: 10),
            SensorActiveArea(left: 0, top: 1, width: 20, height: 10, fullWidth: 20, fullHeight: 10),
            SensorActiveArea(left: 0, top: 0, width: 0, height: 10, fullWidth: 20, fullHeight: 10),
            // Claims a readout larger than the buffer.
            SensorActiveArea(left: 0, top: 0, width: 20, height: 10, fullWidth: 20, fullHeight: 11),
        ]
        for area in outside {
            XCTAssertNil(samples.withUnsafeBufferPointer { SensorPlane(copying: area, of: $0) }, "\(area)")
        }
    }

    // MARK: - Through LibRaw and the shim

    /// A headerless raw that LibRaw recognises by its size alone, from its
    /// table of simple cameras (identify.cpp), so the test needs no sample
    /// file: `width x height` bytes, one per photosite. Active photosites
    /// hold 40 x (colour + 1) plus a little position noise, the colour
    /// taken from the table's pattern at the table's margins.
    private func writeTableCamera(width: Int, height: Int, tableLeft: Int, tableTop: Int,
                                  tablePattern: UInt8) throws -> (URL, [UInt8]) {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for row in 0..<height {
            for col in 0..<width {
                let colour = cfaColour(tablePattern, x: col - tableLeft, y: row - tableTop)
                bytes[row * width + col] = UInt8(40 * (colour + 1) + (row * 7 + col * 3) % 30)
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("active-area-\(UUID().uuidString).raw")
        try Data(bytes).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (url, bytes)
    }

    /// Checks the plane against the file: the active area's photosites, in
    /// order, each the colour the reported pattern says.
    private func assertPlane(of raw: RawFile, matches bytes: [UInt8], fileWidth: Int,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let summary = raw.summary
        let area = summary.activeArea
        guard case .bayer(let pattern) = summary.cfaPattern else {
            return XCTFail("expected a Bayer pattern", file: file, line: line)
        }
        let plane = try XCTUnwrap(raw.sensorPlane, file: file, line: line)
        XCTAssertEqual(plane.count, summary.rawWidth * summary.rawHeight, file: file, line: line)
        let samples = Array(plane.samples)
        var wrongSample = 0, wrongColour = 0
        for y in 0..<area.height {
            for x in 0..<area.width {
                let value = Int(samples[y * area.width + x])
                if value != Int(bytes[(area.top + y) * fileWidth + area.left + x]) { wrongSample += 1 }
                if value / 40 - 1 != cfaColour(pattern, x: x, y: y) { wrongColour += 1 }
            }
        }
        XCTAssertEqual(wrongSample, 0, "photosites not from the active area", file: file, line: line)
        XCTAssertEqual(wrongColour, 0, "photosites whose colour disagrees with the pattern", file: file, line: line)
    }

    /// Kodak DC20: 256 x 244 readout, active area inset on every side.
    /// LibRaw evens the table's 1-pixel margins to 2 and turns the
    /// pattern to match; the plane follows whatever LibRaw reports.
    func testLibRawMarginsAndPaddingAreCutAway() throws {
        let (url, bytes) = try writeTableCamera(width: 256, height: 244, tableLeft: 1, tableTop: 1, tablePattern: 0x8D)
        let file = try RawFile(path: url.path)
        XCTAssertEqual(file.summary.cameraModel, "DC20")
        XCTAssertEqual(file.summary.activeArea,
                       SensorActiveArea(left: 2, top: 2, width: 248, height: 241, fullWidth: 256, fullHeight: 244))
        XCTAssertEqual(file.summary.rawWidth, 248)
        XCTAssertEqual(file.summary.rawHeight, 241)
        try assertPlane(of: file, matches: bytes, fileWidth: 256)

        // The service's reply carries the same rectangle, and a plane count
        // that matches it (checked on the app side before adoption).
        let meta = try JSONDecoder().decode(RawSnapshotMetadata.self,
                                            from: JSONEncoder().encode(file.snapshotMetadata))
        XCTAssertEqual(meta.summary.activeArea, file.summary.activeArea)
        XCTAssertEqual(meta.planeSampleCount, meta.width * meta.height)

        // A metadata-only open (the catalog's) reports the same size.
        let catalogView = try RawFile(path: url.path, metadataOnly: true)
        XCTAssertEqual(catalogView.summary.activeArea, file.summary.activeArea)
    }

    /// Creative PC-CAM 600: the table puts the picture one row down, an
    /// odd margin. The colours in the file follow the table's pattern from
    /// there; the plane and its reported pattern must still agree.
    func testLibRawOddMarginKeepsTheBayerPhase() throws {
        let (url, bytes) = try writeTableCamera(width: 1024, height: 769, tableLeft: 0, tableTop: 1, tablePattern: 0x49)
        let file = try RawFile(path: url.path)
        XCTAssertEqual(file.summary.cameraModel, "PC-CAM 600")
        XCTAssertEqual(file.summary.activeArea,
                       SensorActiveArea(left: 0, top: 2, width: 1024, height: 767, fullWidth: 1024, fullHeight: 769))
        try assertPlane(of: file, matches: bytes, fileWidth: 1024)
    }

    // MARK: - Real files

    /// What LibRaw 0.22.2 reports for the sample files (read with its own
    /// API, outside Latent): no border at all on the D750, so for these
    /// the fix changes nothing, and the render must be exactly this size.
    static let knownAreas: [String: SensorActiveArea] = {
        let d750 = SensorActiveArea(left: 0, top: 0, width: 6032, height: 4032, fullWidth: 6032, fullHeight: 4032)
        return ["golden_nikon_d750_cc0.nef": d750, "nikon_d750_sample.nef": d750,
                "HSB_2615.NEF": d750, "HSB_2639.NEF": d750, "HSB_6548.NEF": d750, "HSB_6664.NEF": d750]
    }()

    func testFullRenderIsLibRawsVisibleSize() throws {
        let present = Self.knownAreas.keys.sorted().filter { FileManager.default.fileExists(atPath: TestAssets.path($0)) }
        try XCTSkipIf(present.isEmpty, "No sample raws in TestAssets — see TestAssets/README.md")
        let gpu = try GPUContext()
        let pipeline = RenderPipeline(gpu: gpu)
        for name in present {
            try autoreleasepool {
                let file = try RawFile(path: TestAssets.path(name))
                XCTAssertEqual(file.summary.activeArea, Self.knownAreas[name], name)
                let session = try ImageSession(file: file, gpu: gpu)
                let texture = try pipeline.render(session)
                XCTAssertEqual(texture.width, Self.knownAreas[name]?.width, name)
                XCTAssertEqual(texture.height, Self.knownAreas[name]?.height, name)
            }
        }
    }
}

/// Edits saved while the plane was the whole readout keep their place on
/// the picture when read against the active area.
final class ActiveAreaMigrationTests: XCTestCase {
    /// A Canon-like readout: a wide masked strip on the left, a short one on top.
    let canon = SensorActiveArea(left: 146, top: 48, width: 6742, height: 4498, fullWidth: 6888, fullHeight: 4546)

    /// Where a legacy normalized point was, in readout pixels, minus the border.
    private func activePixel(_ p: SIMD2<Float>, _ a: SensorActiveArea) -> SIMD2<Float> {
        p * SIMD2(Float(a.fullWidth), Float(a.fullHeight)) - SIMD2(Float(a.left), Float(a.top))
    }

    private func legacyStack() -> EditStack {
        var p = EditParameters()
        p.heals = [HealPatch(target: [0.3, 0.4], source: [0.35, 0.42], radius: 0.01,
                             stroke: [[0, 0], [0.02, 0.01]])]
        p.redEyes = [RedEyeSpot(centre: [0.6, 0.5], radius: 0.006)]
        p.locals = [
            LocalAdjustment(name: "grad", shape: .linear(start: [0.1, 0.2], end: [0.9, 0.8]), exposureEV: 1),
            LocalAdjustment(name: "radial", shape: .radial(centre: [0.5, 0.5], radii: [0.2, 0.1], feather: 0.3)),
            LocalAdjustment(name: "brush", shape: .brush(strokes: [
                BrushStroke(points: [[0.2, 0.2], [0.25, 0.3]], radius: 0.02, feather: 0.5, flow: 1, erase: false)])),
            LocalAdjustment(name: "click", shape: .prompted(points: [MaskPromptPoint(x: 0.7, y: 0.3, foreground: true)],
                                                           modelVersion: "sam2")),
        ]
        p.crop = CropParameters(centre: [0.55, 0.5], size: [0.6, 0.7], angle: 3)
        var stack = EditStack(parameters: p)
        stack.frame = nil   // as written before the change
        return stack
    }

    func testGeometryKeepsItsPixelsOnThePicture() throws {
        let old = legacyStack()
        let new = old.migratingGeometry(to: canon)
        XCTAssertEqual(new.frame, EditStack.activeAreaFrame)
        let size = SIMD2<Float>(Float(canon.width), Float(canon.height))
        let shortOld = Float(min(canon.fullWidth, canon.fullHeight)), shortNew = Float(min(canon.width, canon.height))
        func same(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ what: String) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.05, what); XCTAssertEqual(a.y, b.y, accuracy: 0.05, what)
        }

        let oldHeal = try XCTUnwrap(old.modules.heal?.first), newHeal = try XCTUnwrap(new.modules.heal?.first)
        same(newHeal.target * size, activePixel(oldHeal.target, canon), "heal target")
        same(newHeal.source * size, activePixel(oldHeal.source, canon), "heal source")
        XCTAssertEqual(newHeal.radius * shortNew, oldHeal.radius * shortOld, accuracy: 0.01)
        let oldEnd = oldHeal.target + oldHeal.stroke![1], newEnd = newHeal.target + newHeal.stroke![1]
        same(newEnd * size, activePixel(oldEnd, canon), "stroke end")

        let oldSpot = try XCTUnwrap(old.modules.redeye?.first), newSpot = try XCTUnwrap(new.modules.redeye?.first)
        same(newSpot.centre * size, activePixel(oldSpot.centre, canon), "red-eye")
        XCTAssertEqual(newSpot.radius * shortNew, oldSpot.radius * shortOld, accuracy: 0.01)

        let locals = try XCTUnwrap(new.modules.locals)
        guard case .linear(let start, let end) = locals[0].shape else { return XCTFail() }
        same(start * size, activePixel([0.1, 0.2], canon), "gradient start")
        same(end * size, activePixel([0.9, 0.8], canon), "gradient end")
        guard case .radial(let centre, let radii, _) = locals[1].shape else { return XCTFail() }
        same(centre * size, activePixel([0.5, 0.5], canon), "radial centre")
        XCTAssertEqual(radii.x * shortNew, 0.2 * shortOld, accuracy: 0.01)
        guard case .brush(let strokes) = locals[2].shape else { return XCTFail() }
        same(strokes[0].points[1] * size, activePixel([0.25, 0.3], canon), "brush point")
        XCTAssertEqual(strokes[0].radius * shortNew, 0.02 * shortOld, accuracy: 0.01)
        guard case .prompted(let points, _) = locals[3].shape else { return XCTFail() }
        same(SIMD2(points[0].x, points[0].y) * size, activePixel([0.7, 0.3], canon), "prompt click")
        XCTAssertEqual(locals[0].exposureEV, 1)

        let oldCrop = try XCTUnwrap(old.modules.crop), newCrop = try XCTUnwrap(new.modules.crop)
        same(SIMD2(newCrop.cx, newCrop.cy) * size, activePixel([oldCrop.cx, oldCrop.cy], canon), "crop centre")
        XCTAssertEqual(newCrop.w * size.x, oldCrop.w * Float(canon.fullWidth), accuracy: 0.05)
        XCTAssertEqual(newCrop.h * size.y, oldCrop.h * Float(canon.fullHeight), accuracy: 0.05)
        XCTAssertEqual(newCrop.angle, oldCrop.angle)

        // Converted once only; and the result survives a save and reload.
        XCTAssertEqual(new.migratingGeometry(to: canon), new)
        let reloaded = try EditStack.decode(json: new.encodeJSON())
        XCTAssertEqual(reloaded.migratingGeometry(to: canon), reloaded)
        XCTAssertEqual(EditStack(parameters: reloaded.parameters()).frame, EditStack.activeAreaFrame)
    }

    /// Dust spots and blemishes move exactly as a heal patch does; a face
    /// box keeps its corner pixel and its size in pixels; the landmark
    /// version and the sliders come through untouched.
    func testDustBlemishesAndFaceBoxesMoveLikeHeals() throws {
        var p = EditParameters()
        let patch = HealPatch(target: [0.3, 0.4], source: [0.35, 0.42], radius: 0.01)
        p.heals = [patch]
        p.dust = [patch]
        p.touchUp.blemishes = [patch]
        p.touchUp.blemishRemoval = true
        p.touchUp.faces = [TouchUpFace(boundingBox: SIMD4(0.41, 0.18, 0.12, 0.17))]
        p.touchUp.skinSmoothing = 45
        p.touchUp.modelVersion = "vision.faceLandmarks.3"
        var old = EditStack(parameters: p)
        old.frame = nil
        let new = old.migratingGeometry(to: canon)
        XCTAssertEqual(new.frame, EditStack.activeAreaFrame)
        let heal = try XCTUnwrap(new.modules.heal?.first)
        XCTAssertNotEqual(heal, patch, "it moved")
        XCTAssertEqual(new.modules.dust, [heal])
        XCTAssertEqual(new.modules.touchup?.blemishes, [heal])
        let face = try XCTUnwrap(new.modules.touchup?.faces.first)
        let size = SIMD2<Float>(Float(canon.width), Float(canon.height))
        let corner = SIMD2(face.boundingBox.x, face.boundingBox.y) * size
        XCTAssertEqual(corner.x, activePixel([0.41, 0.18], canon).x, accuracy: 0.05)
        XCTAssertEqual(corner.y, activePixel([0.41, 0.18], canon).y, accuracy: 0.05)
        XCTAssertEqual(face.boundingBox.z * size.x, 0.12 * Float(canon.fullWidth), accuracy: 0.05)
        XCTAssertEqual(face.boundingBox.w * size.y, 0.17 * Float(canon.fullHeight), accuracy: 0.05)
        XCTAssertTrue(face.enabled)
        XCTAssertEqual(face.id, p.touchUp.faces[0].id)
        XCTAssertEqual(new.modules.touchup?.modelVersion, "vision.faceLandmarks.3")
        XCTAssertEqual(new.modules.touchup?.skinSmoothing, 45)
        XCTAssertEqual(new.migratingGeometry(to: canon), new, "once only")

        // Sliders alone are not geometry: nothing to move, nothing marked.
        var slidersOnly = EditStack()
        slidersOnly.modules.touchup = TouchUp()
        slidersOnly.modules.touchup?.eyes = 20
        XCTAssertEqual(slidersOnly.migratingGeometry(to: canon), slidersOnly)
        XCTAssertNil(slidersOnly.migratingGeometry(to: canon).frame)
        // Dust alone is.
        var dustOnly = EditStack()
        dustOnly.modules.dust = [patch]
        XCTAssertEqual(dustOnly.migratingGeometry(to: canon).modules.dust, [heal])
    }

    func testCameraWithoutABorderOnlyGetsMarked() {
        let d750 = SensorActiveArea(left: 0, top: 0, width: 6032, height: 4032, fullWidth: 6032, fullHeight: 4032)
        let old = legacyStack()
        var expected = old
        expected.frame = EditStack.activeAreaFrame
        XCTAssertEqual(old.migratingGeometry(to: d750), expected)
    }

    func testStacksWithoutGeometryAreUntouchedAndEncodeAsBefore() throws {
        var p = EditParameters()
        p.exposureEV = 0.7
        let stack = EditStack(parameters: p)
        XCTAssertNil(stack.frame)
        XCTAssertEqual(stack.migratingGeometry(to: canon), stack)
        XCTAssertFalse(try stack.encodeJSON().contains("frame"))
        // An old stack with only a look.
        let old = try EditStack.decode(json: #"{"schema":1,"process":"1.0","modules":{"exposure":{"ev":0.5}}}"#)
        XCTAssertEqual(old.migratingGeometry(to: canon), old)
    }

    func testNoCropStaysNoCropAndABorderCropIsBroughtInside() throws {
        var locked = EditStack()
        locked.modules.crop = .init(cx: 0.5, cy: 0.5, w: 1, h: 1, angle: 0, aspect: 1.5)
        XCTAssertEqual(locked.migratingGeometry(to: canon).modules.crop, locked.modules.crop)

        // Cropped just the masked strip off the left edge, before the change.
        var old = EditStack()
        let left = Float(canon.left - 20) / Float(canon.fullWidth)   // reaches 20 px into the strip
        old.modules.crop = .init(cx: (left + 1) / 2, cy: 0.5, w: 1 - left, h: 0.8, angle: 0, aspect: nil)
        let crop = try XCTUnwrap(old.migratingGeometry(to: canon).modules.crop)
        XCTAssertEqual(crop.cx - crop.w / 2, 0, accuracy: 1e-5)
        XCTAssertEqual(crop.cx + crop.w / 2, 1, accuracy: 1e-4)
        XCTAssertLessThanOrEqual(crop.w, 1)
    }

    func testMergingKeepsEachSidesFrame() {
        let old = legacyStack()
        var look = EditParameters()
        look.exposureEV = 1
        let pastedLook = EditStack(parameters: look)
        // A look pasted onto an unopened old edit: its geometry is still old.
        XCTAssertNil(old.merged(with: pastedLook, groups: [.tone]).frame)
        // Geometry copied from a converted edit carries its frame along...
        let converted = old.migratingGeometry(to: canon)
        XCTAssertEqual(converted.restricted(to: [.heal]).frame, EditStack.activeAreaFrame)
        XCTAssertEqual(pastedLook.merged(with: converted, groups: [.crop]).frame, EditStack.activeAreaFrame)
        // ...and a stack left with none has no frame, so it equals a fresh one.
        XCTAssertNil(converted.restricted(to: [.tone]).frame)
        XCTAssertEqual(EditStack().merged(with: converted, groups: [.locals, .crop, .heal])
            .merged(with: EditStack(), groups: [.locals, .crop, .heal]), EditStack())
    }
}
