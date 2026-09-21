import XCTest
import CoreGraphics
import simd
import RawCore
import PixelEngine
@testable import MLKit

/// Find Blemishes on the drawn face of TouchUpRegionsTests with spots
/// painted on it (always), and on the portrait fixture through the
/// public entry (skipped when it hasn't been fetched).
final class BlemishFinderTests: XCTestCase {
    /// The drawn face is 600 x 800 analysis pixels at span 2: the sensor
    /// is 1200 x 1600 and the mask set 600 x 800, the same grid.
    static let rawSize = SIMD2<Float>(1200, 1600)

    struct Spot {
        var centre: SIMD2<Float>     // analysis px
        var radius: CGFloat
        var colour: (CGFloat, CGFloat, CGFloat)
    }

    /// The face with `spots` painted on and a little noise over every
    /// pixel, so the detector's noise estimate is a real one rather than
    /// zero (a flat drawing has no residual to measure).
    static func face(with spots: [Spot]) throws -> CGImage {
        let base = TouchUpRegionsTests.drawnFace()
        let width = base.width, height = base.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let image: CGImage? = pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.draw(base, in: CGRect(x: 0, y: 0, width: width, height: height))
            // Core Graphics is y-up: flip so the spots read top-left.
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            for spot in spots {
                context.setFillColor(red: spot.colour.0 / 255, green: spot.colour.1 / 255, blue: spot.colour.2 / 255, alpha: 1)
                context.fillEllipse(in: CGRect(x: CGFloat(spot.centre.x) - spot.radius, y: CGFloat(spot.centre.y) - spot.radius,
                                               width: 2 * spot.radius, height: 2 * spot.radius))
            }
            context.flush()
            // ±2 code values of noise, from a fixed generator.
            var state: UInt32 = 12345
            for i in 0..<(width * height) {
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise = Int(state >> 30) - 2
                for c in 0..<3 {
                    let v = Int(bytes[i * 4 + c]) + noise
                    bytes[i * 4 + c] = UInt8(min(max(v, 0), 255))
                }
            }
            return context.makeImage()
        }
        return try XCTUnwrap(image)
    }

    /// The drawn face's module and mask set.
    static func faceAndMasks(render: TouchUpAnalysis.Render) throws -> (TouchUp, TouchUpMaskSet) {
        let id = UUID()
        let plane = try XCTUnwrap(FaceMaskBuilder.build(TouchUpRegionsTests.drawnLandmarks(), id: id, render: render,
                                                         setWidth: 600, setHeight: 800))
        var touchUp = TouchUp()
        touchUp.faces = [TouchUpFace(id: id, boundingBox: SIMD4(0.25, 0.25, 0.5, 0.5))]
        let masks = TouchUpMaskSet(faces: [plane], width: 600, height: 800, modelVersion: FaceLandmarker.modelVersion)
        return (touchUp, masks)
    }

    /// A raw-normalised point as analysis pixels of the drawn face.
    static func analysisPoint(_ n: SIMD2<Float>) -> SIMD2<Float> { n * rawSize / 2 - 0.5 }

    static let skin: (CGFloat, CGFloat, CGFloat) = (222, 175, 145)
    static let dark: (CGFloat, CGFloat, CGFloat) = (160, 120, 100)
    static let red: (CGFloat, CGFloat, CGFloat) = (225, 120, 120)

    /// Spots on the cheeks and the forehead become patches on the skin,
    /// with their sources on the skin; a spot on the grey beside the face
    /// does not, and a spot under a patch the user already placed is not
    /// healed twice.
    func testFindsSpotsOnSkinAndLeavesTheRestAlone() throws {
        let cheekLeft = SIMD2<Float>(220, 450), cheekRight = SIMD2<Float>(380, 450)
        let forehead = SIMD2<Float>(300, 262), redSpot = SIMD2<Float>(250, 410)
        let beside = SIMD2<Float>(100, 400)
        let image = try Self.face(with: [
            Spot(centre: cheekLeft, radius: 4, colour: Self.dark), Spot(centre: cheekRight, radius: 5, colour: Self.dark),
            Spot(centre: forehead, radius: 4, colour: Self.dark), Spot(centre: redSpot, radius: 4, colour: Self.red),
            Spot(centre: beside, radius: 5, colour: (60, 60, 60))])
        let render = TouchUpAnalysis.Render(image: image, span: 2, rotation: .none)
        let (touchUp, masks) = try Self.faceAndMasks(render: render)

        let found = BlemishFinder.find(in: render, masks: masks, touchUp: touchUp, existing: [], rawSize: Self.rawSize) { $0 }
        func patch(near spot: SIMD2<Float>) -> HealPatch? {
            found.first { simd_distance(Self.analysisPoint($0.target), spot) < 3 }
        }
        XCTAssertNotNil(patch(near: cheekLeft), "left cheek: \(found)")
        XCTAssertNotNil(patch(near: cheekRight), "right cheek: \(found)")
        XCTAssertNotNil(patch(near: forehead), "forehead: \(found)")
        XCTAssertNotNil(patch(near: redSpot), "the red spot: \(found)")
        XCTAssertNil(patch(near: beside), "the grey beside the face has no skin weight")
        XCTAssertEqual(found.count, 4, "\(found)")

        let plane = masks.faces[0]
        for patch in found {
            // The patch reaches 1.6 times past a 4–5 px blob at span 2:
            // 13–16 sensor px of a 1200 px short side.
            XCTAssertEqual(patch.radius, 0.012, accuracy: 0.005, "\(patch)")
            XCTAssertEqual(patch.feather, 0.5)
            XCTAssertEqual(patch.mode, .heal)
            // The source sits 2.5 patch radii away, on the skin.
            let apart = simd_length((patch.source - patch.target) * Self.rawSize)
            XCTAssertEqual(apart / 1200, 2.5 * patch.radius, accuracy: 0.002)
            let source = Self.analysisPoint(patch.source)
            XCTAssertGreaterThan(TouchUpRegionsTests.value(plane.skin, plane, Int(source.x.rounded()), Int(source.y.rounded())),
                                 127, "source on skin: \(patch)")
        }

        // The forehead spot under a user's patch is left to that patch.
        let healed = HealPatch(target: (forehead + 0.5) * 2 / Self.rawSize, source: SIMD2(0.6, 0.3), radius: 12 / 1200)
        let rest = BlemishFinder.find(in: render, masks: masks, touchUp: touchUp, existing: [healed],
                                      rawSize: Self.rawSize) { $0 }
        XCTAssertEqual(rest.count, 3)
        XCTAssertNil(rest.first { simd_distance(Self.analysisPoint($0.target), forehead) < 3 })
        // Nor is a source placed inside it.
        for patch in rest {
            XCTAssertGreaterThan(simd_distance(patch.source * Self.rawSize, healed.target * Self.rawSize),
                                 (patch.radius + healed.radius) * 1200 - 0.01)
        }
    }

    /// A face switched off is not looked at, and a face with no mask
    /// (Vision could not find it again) gives nothing rather than a crash.
    func testDisabledOrMasklessFacesGiveNothing() throws {
        let image = try Self.face(with: [Spot(centre: SIMD2(220, 450), radius: 4, colour: Self.dark)])
        let render = TouchUpAnalysis.Render(image: image, span: 2, rotation: .none)
        var (touchUp, masks) = try Self.faceAndMasks(render: render)
        touchUp.faces[0].enabled = false
        XCTAssertTrue(BlemishFinder.find(in: render, masks: masks, touchUp: touchUp, existing: [],
                                         rawSize: Self.rawSize) { $0 }.isEmpty)
        touchUp.faces[0].enabled = true
        masks.faces[0] = .init(id: touchUp.faces[0].id, origin: SIMD2(0, 0), width: 0, height: 0, skin: [], teeth: [], eyes: [])
        XCTAssertTrue(BlemishFinder.find(in: render, masks: masks, touchUp: touchUp, existing: [],
                                         rawSize: Self.rawSize) { $0 }.isEmpty)
    }

    /// A lens map moves the target and the source alike: with every
    /// output point shifted, the patches shift by the same amount.
    func testTargetsGoThroughTheRawMap() throws {
        let image = try Self.face(with: [Spot(centre: SIMD2(220, 450), radius: 4, colour: Self.dark)])
        let render = TouchUpAnalysis.Render(image: image, span: 2, rotation: .none)
        let (touchUp, masks) = try Self.faceAndMasks(render: render)
        let straight = BlemishFinder.find(in: render, masks: masks, touchUp: touchUp, existing: [], rawSize: Self.rawSize) { $0 }
        let shifted = BlemishFinder.find(in: render, masks: masks, touchUp: touchUp, existing: [],
                                         rawSize: Self.rawSize) { $0 + SIMD2(10, -6) }
        XCTAssertEqual(straight.count, 1)
        XCTAssertEqual(shifted.count, 1)
        let delta = SIMD2<Float>(10, -6) / Self.rawSize
        XCTAssertEqual(simd_distance(shifted[0].target, straight[0].target + delta), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(shifted[0].source, straight[0].source + delta), 0, accuracy: 1e-5)
    }

    /// The public entry on the portrait: whatever it finds lies on the
    /// face, is capped, and heals from the skin.
    func testPortraitBlemishesLieOnTheFace() throws {
        let url = try PortraitFixture.dngURL()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: url.path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        let parameters = try ExportPlan.parameters(editStackJSON: nil, session: session, colorSpace: .sRGB)
        let rotation = ExportPlan.rotation(for: session.file.summary, userRotation: 0)
        let render = try TouchUpAnalysis.render(session: session, pipeline: pipeline, gpu: gpu,
                                                parameters: parameters, rotation: rotation)
        let faces = TouchUpRegions.find(in: render, session: session, pipeline: pipeline, parameters: parameters)
        var touchUp = TouchUp()
        touchUp.faces = faces.faces
        let started = Date()
        let found = BlemishFinder.find(in: render, masks: faces.masks, touchUp: touchUp, existing: [],
                                       session: session, pipeline: pipeline, parameters: parameters)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThanOrEqual(found.count, HealPatch.maximumBlemishCount)
        let box = try XCTUnwrap(faces.faces.first).boundingBox
        let loose = CGRect(x: CGFloat(box.x), y: CGFloat(box.y), width: CGFloat(box.z), height: CGFloat(box.w))
            .insetBy(dx: -CGFloat(box.z) * 0.3, dy: -CGFloat(box.w) * 0.4)
        for patch in found {
            XCTAssertTrue(loose.contains(CGPoint(x: CGFloat(patch.target.x), y: CGFloat(patch.target.y))), "\(patch)")
            XCTAssertTrue(loose.contains(CGPoint(x: CGFloat(patch.source.x), y: CGFloat(patch.source.y))), "\(patch)")
        }
        print("Find Blemishes on the portrait: \(Int(elapsed * 1000)) ms, \(found.count) blemishes")
    }
}
