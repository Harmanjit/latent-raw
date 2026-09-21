import XCTest
import Metal
import simd
@testable import PixelEngine
@testable import RawCore

/// The touch-up module (docs/Retouch.md §3, §7, §11): its stored form,
/// caps and clamps, how it copies and pastes, the region mask set and
/// the session's mask texture, and the stage's place in the pipeline.
final class TouchUpTests: XCTestCase {
    private func face(_ x: Float, enabled: Bool = true, width: Float = 0.12) -> TouchUpFace {
        TouchUpFace(boundingBox: SIMD4(x, 0.18, width, 0.17), enabled: enabled)
    }

    private func blemish(_ x: Float, _ y: Float) -> HealPatch {
        HealPatch(target: [x, y], source: [x + 0.006, y - 0.002], radius: 0.0018, feather: 0.5, mode: .heal)
    }

    /// Faces, sliders and blemishes, as Find Faces and Find Blemishes leave it.
    private func edited() -> TouchUp {
        var t = TouchUp()
        t.faces = [face(0.41), face(0.6, enabled: false)]
        t.skinSmoothing = 45; t.teethWhitening = 30; t.eyes = 20
        t.blemishRemoval = true
        t.blemishes = [blemish(0.452, 0.271), blemish(0.47, 0.3)]
        t.modelVersion = "vision.faceLandmarks.3"
        return t
    }

    // MARK: - Stored form

    func testNeutralEncodesNothing() throws {
        XCTAssertTrue(TouchUp().isNeutral)
        XCTAssertTrue(TouchUp.neutral.isNeutral)
        XCTAssertNil(EditStack(parameters: EditParameters()).modules.touchup)
        XCTAssertFalse(try EditStack(parameters: EditParameters()).encodeJSON().contains("touchup"))
        XCTAssertEqual(EditParameters().touchUp, .neutral)
        XCTAssertFalse(TouchUp().wantsMasks)
        // Sliders alone are a module, but not a place: no frame.
        var p = EditParameters()
        p.touchUp.skinSmoothing = 45
        let stack = EditStack(parameters: p)
        XCTAssertNotNil(stack.modules.touchup)
        XCTAssertNil(stack.frame)
        XCTAssertFalse(EditStack.isDefault(p, relativeTo: EditParameters()))
    }

    func testRoundTrip() throws {
        var p = EditParameters()
        p.touchUp = edited()
        let stack = EditStack(parameters: p)
        XCTAssertEqual(stack.frame, EditStack.activeAreaFrame, "faces and blemishes are geometry")
        let json = try stack.encodeJSON()
        XCTAssertTrue(json.contains("\"touchup\""))
        XCTAssertTrue(json.contains("\"boundingBox\":[0.41,0.18,0.12,0.17]"))
        let back = try EditStack.decode(json: json)
        XCTAssertEqual(back, stack)
        XCTAssertEqual(back.parameters().touchUp, p.touchUp)
        XCTAssertEqual(back.parameters().touchUp.modelVersion, "vision.faceLandmarks.3")
        XCTAssertNotEqual(p, EditParameters())
        XCTAssertTrue(stack.presentGroups.contains(.touchUp))
        XCTAssertFalse(EditGroup.lookGroups.contains(.touchUp))
        XCTAssertEqual(EditGroup.touchUp.displayName, "Touch-up (skin, teeth, eyes, blemishes)")
        XCTAssertEqual(EditHistory.describeChange(from: EditStack(parameters: EditParameters()), to: stack), "Touch-up")
    }

    func testPartialJSONLoadsLeniently() throws {
        let stack = try EditStack.decode(json: #"{"schema":1,"process":"1.0","modules":{"touchup":{"skinSmoothing":45}}}"#)
        let t = stack.parameters().touchUp
        XCTAssertEqual(t.skinSmoothing, 45)
        XCTAssertEqual(t.faces, [])
        XCTAssertEqual(t.blemishes, [])
        XCTAssertFalse(t.blemishRemoval)
        XCTAssertEqual(t.modelVersion, "")
        XCTAssertFalse(t.wantsMasks, "no face yet")

        let faces = try EditStack.decode(json: #"{"schema":1,"process":"1.0","modules":{"touchup":{"faces":[{"boundingBox":[0.4,0.2,0.1,0.15]},{}],"eyes":20}}}"#)
        let f = faces.parameters().touchUp
        XCTAssertEqual(f.faces.count, 2)
        XCTAssertEqual(f.faces[0].boundingBox, SIMD4(0.4, 0.2, 0.1, 0.15))
        XCTAssertTrue(f.faces[0].enabled)
        XCTAssertEqual(f.faces[1].boundingBox, SIMD4(0, 0, 0, 0))
        XCTAssertTrue(f.wantsMasks)
        XCTAssertEqual(f.enabledFaceIDs, Set(f.faces.map(\.id)))
        XCTAssertEqual(try JSONDecoder().decode(TouchUp.self, from: Data("{}".utf8)), .neutral)
    }

    func testCapsAndClamps() throws {
        var t = TouchUp()
        t.faces = (0..<20).map { face(Float($0) / 20) }
        t.blemishes = (0..<70).map { blemish(Float($0) / 70, 0.5) }
        t.skinSmoothing = 150; t.teethWhitening = -5; t.eyes = .nan
        let s = t.sanitized
        XCTAssertEqual(s.faces.count, TouchUp.maximumFaces)
        XCTAssertEqual(s.faces.first?.boundingBox.x, 0)
        XCTAssertEqual(s.blemishes.count, HealPatch.maximumBlemishCount)
        XCTAssertEqual(s.skinSmoothing, 100)
        XCTAssertEqual(s.teethWhitening, 0)
        XCTAssertEqual(s.eyes, 0)
        // The stack applies the same on decode.
        var stack = EditStack()
        stack.modules.touchup = t
        XCTAssertEqual(stack.parameters().touchUp, s)

        // A face whose box isn't a number is dropped; one off the sensor
        // comes back within a frame of it; a bad blemish is dropped.
        var bad = TouchUp()
        bad.faces = [TouchUpFace(boundingBox: SIMD4(.nan, 0, 0.1, 0.1)),
                     TouchUpFace(boundingBox: SIMD4(-7, 0.2, 9, 0.1))]
        bad.blemishes = [HealPatch(target: [.infinity, 0], source: [0, 0], radius: 0.001)]
        let cleaned = bad.sanitized
        XCTAssertEqual(cleaned.faces.count, 1)
        XCTAssertEqual(cleaned.faces[0].boundingBox, SIMD4(-1, 0.2, 2, 0.1))
        XCTAssertEqual(cleaned.blemishes, [])
        let made = edited()
        XCTAssertEqual(made.sanitized, made, "what the app made comes back unchanged")
    }

    func testWantsMasksNeedsAnEnabledFaceAndASlider() {
        var t = TouchUp()
        t.faces = [face(0.4, enabled: false)]
        t.skinSmoothing = 45
        XCTAssertFalse(t.wantsMasks)
        t.faces[0].enabled = true
        XCTAssertTrue(t.wantsMasks)
        t.skinSmoothing = 0
        XCTAssertFalse(t.wantsMasks)
        t.eyes = 1
        XCTAssertTrue(t.wantsMasks)
        // Blemishes need no masks, and count only when Remove Blemishes is on.
        t.eyes = 0
        t.blemishes = [blemish(0.5, 0.5)]
        XCTAssertFalse(t.wantsMasks)
        XCTAssertEqual(t.activeBlemishes, [])
        t.blemishRemoval = true
        XCTAssertEqual(t.activeBlemishes, t.blemishes)
    }

    // MARK: - Copy, paste, presets

    func testMergedKeepsTheDestinationsFacesAndBlemishes() throws {
        var a = EditParameters(); a.touchUp = edited(); a.touchUp.skinSmoothing = 10
        var b = EditParameters(); b.touchUp = edited(); b.touchUp.skinSmoothing = 70
        b.touchUp.faces = [face(0.9)]
        b.touchUp.blemishes = [blemish(0.9, 0.9)]
        let merged = EditStack(parameters: a).merged(with: EditStack(parameters: b), groups: [.touchUp])
        let t = try XCTUnwrap(merged.modules.touchup)
        XCTAssertEqual(t.skinSmoothing, 70, "the sliders travel")
        XCTAssertEqual(t.faces, a.touchUp.faces, "the faces are the destination's own")
        XCTAssertEqual(t.blemishes, a.touchUp.blemishes)
        XCTAssertEqual(merged.frame, EditStack.activeAreaFrame)
        // Pasting onto an image without faces gives sliders and no faces.
        let fresh = try XCTUnwrap(EditStack().merged(with: EditStack(parameters: b), groups: [.touchUp]).modules.touchup)
        XCTAssertEqual(fresh.skinSmoothing, 70)
        XCTAssertEqual(fresh.faces, [])
        XCTAssertEqual(fresh.blemishes, [])
        XCTAssertTrue(fresh.blemishRemoval)
        // Pasting "no touch-up" still clears the module.
        XCTAssertNil(EditStack(parameters: a).merged(with: EditStack(), groups: [.touchUp]).modules.touchup)
        // Other groups leave it alone.
        XCTAssertEqual(EditStack(parameters: a).merged(with: EditStack(parameters: b), groups: [.tone]).modules.touchup,
                       a.touchUp)
    }

    func testRestrictedDropsFacesAndBlemishes() throws {
        var p = EditParameters(); p.touchUp = edited(); p.exposureEV = 1
        let clip = EditStack(parameters: p).restricted(to: [.touchUp])
        let t = try XCTUnwrap(clip.modules.touchup)
        XCTAssertEqual(t.skinSmoothing, 45)
        XCTAssertEqual(t.faces, [])
        XCTAssertEqual(t.blemishes, [])
        XCTAssertNil(clip.frame, "nothing left that is a place")
        XCTAssertNil(clip.modules.exposure)
        let preset = Preset(name: "Portrait", groups: [.touchUp], stack: EditStack(parameters: p))
        XCTAssertEqual(preset.stack.modules.touchup?.faces, [])
        XCTAssertNil(EditStack(parameters: p).restricted(to: EditGroup.lookGroups).modules.touchup)
    }

    // MARK: - Scales

    func testMedianFaceWidthAndBlurReach() {
        let sensor = SIMD2<Float>(6000, 4000)
        var t = TouchUp()
        XCTAssertNil(t.medianFaceWidthPixels(sensorSize: sensor))
        t.faces = [face(0.1, width: 0.1), face(0.3, width: 0.3), face(0.5, width: 0.2), face(0.7, enabled: false, width: 0.9)]
        XCTAssertEqual(t.medianFaceWidthPixels(sensorSize: sensor), 1200, "the middle enabled face")
        t.faces.append(face(0.9, width: 0.4))
        XCTAssertEqual(t.medianFaceWidthPixels(sensorSize: sensor), 1500, "even count: the two middles' mean")

        XCTAssertEqual(TouchUp.sigmaMid(faceWidth: nil), 4)
        XCTAssertEqual(TouchUp.sigmaMid(faceWidth: 50), 4, "floor")
        XCTAssertEqual(TouchUp.sigmaMid(faceWidth: 1000), 35, accuracy: 1e-5)
        XCTAssertEqual(TouchUp.sigmaMid(faceWidth: 5000), 48, "ceiling")
        XCTAssertEqual(TouchUp.blurReachPixels(faceWidth: nil), 14)
        XCTAssertEqual(TouchUp.blurReachPixels(faceWidth: 1000), 107)
        XCTAssertEqual(TouchUp.blurReachPixels(faceWidth: 5000), 146)
    }

    // MARK: - Region masks

    func testMaskSetCompositesEnabledFacesWithMax() {
        let a = UUID(), b = UUID(), c = UUID()
        let set = TouchUpMaskSet(faces: [
            TouchUpMaskSet.Face(id: a, origin: SIMD2(1, 1), width: 2, height: 2,
                                skin: [10, 20, 30, 40], teeth: [1, 1, 1, 1], eyes: [255, 128, 0, 5]),
            // Overlaps a's bottom-right pixel with a larger and a smaller value.
            TouchUpMaskSet.Face(id: b, origin: SIMD2(2, 2), width: 2, height: 2,
                                skin: [50, 60, 70, 80], teeth: [0, 0, 0, 0], eyes: [3, 9, 9, 9]),
            // Reaches past the set: clipped, not crashed.
            TouchUpMaskSet.Face(id: c, origin: SIMD2(3, -1), width: 2, height: 2,
                                skin: [90, 90, 90, 90], teeth: [7, 7, 7, 7], eyes: [0, 0, 0, 0]),
        ], width: 4, height: 4, modelVersion: "test")
        let both = set.composite(enabled: [a, b])
        XCTAssertEqual(both.skin, [0, 0, 0, 0,
                                   0, 10, 20, 0,
                                   0, 30, 50, 60,
                                   0, 0, 70, 80])
        XCTAssertEqual(both.eyes[2 * 4 + 2], 5, "max on overlap: a's 5 over b's 3")
        XCTAssertEqual(both.eyes[1 * 4 + 2], 128)
        XCTAssertEqual(both.eyes[2 * 4 + 3], 9)
        XCTAssertEqual(both.teeth[1 * 4 + 1], 1)
        let onlyB = set.composite(enabled: [b])
        XCTAssertEqual(onlyB.skin[1 * 4 + 1], 0)
        XCTAssertEqual(onlyB.skin[2 * 4 + 2], 50)
        let clipped = set.composite(enabled: [c])
        XCTAssertEqual(clipped.skin, [0, 0, 0, 90,
                                      0, 0, 0, 0,
                                      0, 0, 0, 0,
                                      0, 0, 0, 0])
        XCTAssertEqual(set.composite(enabled: []).skin, [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(TouchUpMaskSet.size(sensorWidth: 6032, sensorHeight: 4033).width, 3016)
        XCTAssertEqual(TouchUpMaskSet.size(sensorWidth: 6032, sensorHeight: 4033).height, 2017)
    }

    func testFixtureIsDeterministicAndLaidOutLikeTheRealPlanes() {
        let id = UUID()
        let faces = [(id: id, skin: CGRect(x: 0.4, y: 0.2, width: 0.2, height: 0.3),
                      teeth: CGRect(x: 0.47, y: 0.42, width: 0.06, height: 0.02) as CGRect?,
                      eyes: [CGRect(x: 0.44, y: 0.28, width: 0.04, height: 0.02)])]
        let set = TouchUpMaskSet.fixture(sensorWidth: 1000, sensorHeight: 800, faces: faces)
        XCTAssertEqual(set, TouchUpMaskSet.fixture(sensorWidth: 1000, sensorHeight: 800, faces: faces))
        XCTAssertEqual(set.width, 500)
        XCTAssertEqual(set.height, 400)
        XCTAssertEqual(set.faces.count, 1)
        let face = set.faces[0]
        XCTAssertEqual(face.id, id)
        XCTAssertEqual(face.origin, SIMD2(200, 80))
        XCTAssertEqual(face.width, 100)
        XCTAssertEqual(face.height, 120)
        let planes = set.composite(enabled: [id])
        func at(_ plane: [UInt8], _ x: Int, _ y: Int) -> UInt8 { plane[y * set.width + x] }
        XCTAssertEqual(at(planes.skin, 250, 140), 255)
        XCTAssertEqual(at(planes.skin, 199, 140), 0)
        XCTAssertEqual(at(planes.teeth, 250, 168), 255)
        XCTAssertEqual(at(planes.teeth, 250, 140), 0)
        // The eye: sclera at the corner, iris around the centre, pupil at it.
        XCTAssertEqual(at(planes.eyes, 220, 112), 255)
        XCTAssertEqual(at(planes.eyes, 230, 116), 0)
        XCTAssertEqual(at(planes.eyes, 225, 116), 128)
        XCTAssertEqual(at(planes.eyes, 250, 140), 0)
        XCTAssertEqual(planes.skin.filter { $0 == 255 }.count, 100 * 120)
        XCTAssertEqual(set.modelVersion, "fixture")
    }

    // MARK: - The session and the pipeline

    private func openFixture() throws -> (GPUContext, ImageSession, RenderPipeline) {
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: LinearFixtures.path(LinearFixtures.plain)), gpu: gpu)
        return (gpu, session, RenderPipeline(gpu: gpu))
    }

    private func fixtureSet(_ id: UUID, sensor: SIMD2<Int>) -> TouchUpMaskSet {
        TouchUpMaskSet.fixture(sensorWidth: sensor.x, sensorHeight: sensor.y, faces: [
            (id: id, skin: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), teeth: nil,
             eyes: [CGRect(x: 0.3, y: 0.3, width: 0.1, height: 0.1)])])
    }

    func testSessionBuildsTheMaskTextureOncePerEnabledSet() throws {
        let (_, session, _) = try openFixture()
        let id = UUID(), other = UUID()
        XCTAssertFalse(session.hasTouchUpMasks)
        XCTAssertNil(session.touchUpMaskTexture(enabled: [id]))
        let set = fixtureSet(id, sensor: SIMD2(64, 48))
        session.setTouchUpMasks(set)
        XCTAssertTrue(session.hasTouchUpMasks)
        XCTAssertEqual(session.touchUpMasks, set)
        let texture = try XCTUnwrap(session.touchUpMaskTexture(enabled: [id]))
        XCTAssertEqual(texture.textureType, .type2DArray)
        XCTAssertEqual(texture.arrayLength, 3)
        XCTAssertEqual(texture.pixelFormat, .r8Unorm)
        XCTAssertEqual(texture.width, 32)
        XCTAssertEqual(texture.height, 24)
        XCTAssertTrue(session.touchUpMaskTexture(enabled: [id]) === texture, "reused for the same set")
        let none = try XCTUnwrap(session.touchUpMaskTexture(enabled: [other]))
        XCTAssertFalse(none === texture, "rebuilt when the enabled set changes")
        // The slices hold the composite.
        var skin = [UInt8](repeating: 0, count: 32 * 24), eyes = skin
        texture.getBytes(&skin, bytesPerRow: 32, bytesPerImage: 32 * 24, from: MTLRegionMake2D(0, 0, 32, 24),
                         mipmapLevel: 0, slice: 0)
        texture.getBytes(&eyes, bytesPerRow: 32, bytesPerImage: 32 * 24, from: MTLRegionMake2D(0, 0, 32, 24),
                         mipmapLevel: 0, slice: 2)
        let planes = set.composite(enabled: [id])
        XCTAssertEqual(skin, planes.skin)
        XCTAssertEqual(eyes, planes.eyes)
        XCTAssertEqual(skin[12 * 32 + 16], 255)
        XCTAssertGreaterThan(session.approximateBytesHeld, 0)

        // Critical pressure drops the set and says so, until it is set again.
        XCTAssertFalse(session.droppedTouchUpMasks)
        session.releaseMemory(for: .warning)
        XCTAssertTrue(session.hasTouchUpMasks, "a warning keeps them")
        session.releaseMemory(for: .critical)
        XCTAssertFalse(session.hasTouchUpMasks)
        XCTAssertTrue(session.droppedTouchUpMasks)
        XCTAssertNil(session.touchUpMaskTexture(enabled: [id]))
        session.releaseMemory(for: .critical)
        XCTAssertTrue(session.droppedTouchUpMasks, "still true until set again")
        session.setTouchUpMasks(nil)
        XCTAssertFalse(session.droppedTouchUpMasks)
        session.setTouchUpMasks(set)
        XCTAssertFalse(session.droppedTouchUpMasks)
        XCTAssertNotNil(session.touchUpMaskTexture(enabled: [id]))
    }
}
