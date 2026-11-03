import XCTest
import simd
@testable import MergeKit
import RawCore

/// DNG export's writer pieces: the recipe it records, the colour transform
/// back into camera space, and the original's path.
final class RenderedDNGExportTests: XCTestCase {
    func testRecipeIsARenderedOneWithLensAppliedAndNothingClipped() throws {
        let source = MergeRecipe.Source(path: "../DSC_0107.NEF", hash: "xxh64:ab", captureTime: 1_700_000_000)
        let recipe = RenderedDNGExport.recipe(source: source, maximum: 3)
        XCTAssertEqual(recipe.kind, .rendered)
        XCTAssertTrue(recipe.lensApplied)
        XCTAssertGreaterThan(recipe.clipLevel, 3)
        XCTAssertEqual(recipe.sources, [source])
        let back = try JSONDecoder().decode(MergeRecipe.self, from: JSONEncoder().encode(recipe))
        XCTAssertEqual(back, recipe)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(recipe), as: UTF8.self).contains("\"rendered\""))
    }

    /// The camera matrix's inverse keeps white white, and light no camera
    /// channel can hold is cut at zero rather than stored negative.
    func testCameraSpaceKeepsWhiteAndCutsNegatives() throws {
        // A Nikon D750's matrix, as LibRaw gives it.
        let d750: [Float] = [0.902, -0.289, -0.0715, -0.4535, 1.2436, 0.2348, -0.0934, 0.1919, 0.7086]
        let matrix = try XCTUnwrap(RenderedDNGExport.workingToCamera(cameraToXYZ: d750))
        let white = matrix * SIMD3<Float>(1, 1, 1)
        for c in 0..<3 { XCTAssertEqual(white[c], 1, accuracy: 1e-4) }
        var rgb: [Float16] = [1, 1, 1, 0, 1, 0]
        rgb.withUnsafeMutableBufferPointer { RenderedDNGExport.toCameraSpace($0, matrix: matrix) }
        XCTAssertEqual(Float(rgb[0]), 1, accuracy: 0.002)
        XCTAssertTrue(rgb.allSatisfy { $0 >= 0 })
        XCTAssertNil(RenderedDNGExport.workingToCamera(cameraToXYZ: [0, 0, 0, 0, 0, 0, 0, 0, 0]))
    }

    func testOriginalPathIsRelativeToTheDNGsFolder() {
        let original = URL(fileURLWithPath: "/Users/a/Photos/Day 1/DSC_0107.NEF")
        XCTAssertEqual(RenderedDNGExport.relativePath(of: original, from: URL(fileURLWithPath: "/Users/a/Photos/Day 1")),
                       "DSC_0107.NEF")
        XCTAssertEqual(RenderedDNGExport.relativePath(of: original, from: URL(fileURLWithPath: "/Users/a/Exports/DNG")),
                       "../../Photos/Day 1/DSC_0107.NEF")
        XCTAssertEqual(RenderedDNGExport.relativePath(of: original, from: URL(fileURLWithPath: "/Volumes/Card")),
                       "DSC_0107.NEF")
    }
}
