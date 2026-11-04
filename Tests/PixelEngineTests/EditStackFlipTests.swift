import XCTest
@testable import PixelEngine

/// Photo › Flip on stored edits (EditStack+Flip.swift): the same fields
/// as Develop's Transform flip, and a double flip gives the edit back.
final class EditStackFlipTests: XCTestCase {
    func testFlippingAnUneditedImageSetsOnlyTheTransformFlip() throws {
        let flipped = try EditStack().flipped(horizontal: true)
        XCTAssertEqual(flipped.modules.perspective?.flipHorizontal, true)
        XCTAssertNil(flipped.modules.perspective?.flipVertical)
        XCTAssertNil(flipped.modules.crop)
        // Flipped back, the Transform is neutral again and leaves the stack.
        XCTAssertEqual(try flipped.flipped(horizontal: true), EditStack())
    }

    func testFlipMirrorsTheCropMasksAndSlidersAsDevelopDoes() throws {
        var p = EditParameters()
        p.exposureEV = 0.4
        // Values a float holds exactly, so twice round is exact.
        p.crop = CropParameters(centre: [0.25, 0.625], size: [0.5, 0.5], angle: 4)
        p.perspective.rotate = 2
        p.perspective.horizontal = 0.25
        p.perspective.offsetX = 0.25
        p.locals = [LocalAdjustment(name: "r", shape: .radial(centre: [0.25, 0.75], radii: [0.125, 0.125], feather: 0.5))]
        let stack = EditStack(parameters: p)
        let flipped = try stack.flipped(horizontal: true)

        // What EditorModel.flip does to the parameters.
        var expected = p
        expected.perspective.flip(horizontal: true)
        expected.crop = p.crop.mirrored(horizontal: true)
        expected.locals = p.locals.map { var l = $0; l.shape = $0.shape.mirrored(horizontal: true); return l }
        let got = flipped.parameters()
        XCTAssertEqual(got.perspective, expected.perspective)
        XCTAssertEqual(got.crop.centre.x, expected.crop.centre.x, accuracy: 1e-6)
        XCTAssertEqual(got.crop.centre.y, 0.625, accuracy: 1e-6)
        XCTAssertEqual(got.crop.angle, -4)
        XCTAssertEqual(got.locals.map(\.shape), expected.locals.map(\.shape))
        XCTAssertEqual(got.exposureEV, 0.4, "the rest of the edit is untouched")

        // Twice gives back exactly what was stored, byte for byte.
        let twice = try flipped.flipped(horizontal: true)
        XCTAssertEqual(try twice.encodeJSON(), try stack.encodeJSON())
        let vertical = try stack.flipped(horizontal: false).flipped(horizontal: false)
        XCTAssertEqual(try vertical.encodeJSON(), try stack.encodeJSON())
    }

    func testAnOldReadoutCropIsNotFlippedBlind() throws {
        var stack = EditStack()
        stack.modules.crop = EditStack.Crop(cx: 0.4, cy: 0.5, w: 0.5, h: 0.5, angle: 0, aspect: nil)
        XCTAssertNil(stack.frame)
        XCTAssertThrowsError(try stack.flipped(horizontal: true)) { error in
            XCTAssertEqual(error as? EditStack.FlipError, .legacyGeometry)
        }
        stack.frame = EditStack.activeAreaFrame
        XCTAssertEqual(try stack.flipped(horizontal: true).modules.crop?.cx ?? 0, 0.6, accuracy: 1e-6)
    }
}
