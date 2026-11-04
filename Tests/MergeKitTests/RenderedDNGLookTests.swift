import XCTest
@testable import MergeKit

/// "DNG, full look baked in": the inverse tone curve the pixels are stored
/// under, which Latent's default sigmoid turns back into the edit.
final class RenderedDNGLookTests: XCTestCase {
    func testDefaultSigmoidUndoesTheInverse() {
        let look = RenderedDNGExport.BakedLook(contrast: 1.5, greyPoint: 0.1845)
        func sigmoid(_ x: Float) -> Float {
            let xc = pow(x, 1.5), kc = pow(Float(0.1845), 1.5)
            return xc / (xc + kc)
        }
        for y: Float in [0.001, 0.05, 0.18, 0.5, 0.8, 0.99] {
            XCTAssertEqual(sigmoid(look.sceneValue(display: y)), y, accuracy: 1e-4, "\(y)")
        }
        XCTAssertEqual(look.sceneValue(display: 0.5), 0.1845, accuracy: 1e-5, "mid display is the grey point")
        XCTAssertEqual(look.sceneValue(display: -1), 0)
        XCTAssertTrue(look.sceneValue(display: 1.5).isFinite, "white is held below infinity")
        XCTAssertLessThan(look.sceneValue(display: 1.5), 65504, "within a half float")
        var rgb: [Float16] = [0.5, 0.5, 0.5]
        rgb.withUnsafeMutableBufferPointer { RenderedDNGExport.undoTone($0, look: look) }
        XCTAssertEqual(Float(rgb[0]), 0.1845, accuracy: 0.001)
    }

    func testFullLookRecipeSaysSo() {
        let source = MergeRecipe.Source(path: "a.NEF", hash: "xxh64:0", captureTime: 0)
        let look = RenderedDNGExport.BakedLook(contrast: 1.5, greyPoint: 0.1845)
        XCTAssertEqual(RenderedDNGExport.recipe(source: source, maximum: 2, look: look).options["look"], .string("baked"))
        XCTAssertTrue(RenderedDNGExport.recipe(source: source, maximum: 2).options.isEmpty,
                      "the scene-referred recipe is unchanged")
    }
}
