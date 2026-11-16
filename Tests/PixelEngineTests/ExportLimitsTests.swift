import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PixelEngine
@testable import RawCore

/// Export sizes at the edges: numbers typed far too large clamp rather than
/// trap, and a render never asks the GPU for a texture past its limit.
final class ExportLimitsTests: XCTestCase {
    /// A percentage or megapixels far past any real size comes down to the
    /// largest edge an export may ask for, never an Int overflow.
    func testHugeSizingValuesClampInsteadOfTrapping() {
        let percent = ExportSizing(mode: .percentage, percentage: 1e18, dontEnlarge: false)
        XCTAssertEqual(percent.targetLongEdge(width: 6000, height: 4000), ExportSizing.maximumEdge)
        let mp = ExportSizing(mode: .megapixels, megapixels: 1e40, dontEnlarge: false)
        XCTAssertEqual(mp.targetLongEdge(width: 6000, height: 4000), ExportSizing.maximumEdge)
        XCTAssertEqual(ExportSizing(mode: .percentage, percentage: 1e18).targetLongEdge(width: 6000, height: 4000),
                       6000, "Don't Enlarge still holds the photo's own size")
        XCTAssertEqual(ExportSizing(mode: .megapixels, megapixels: .infinity, dontEnlarge: false)
                        .targetLongEdge(width: 6000, height: 4000), 1225, "not a number: one megapixel")
    }

    /// A full-size render of a photo wider than the GPU's largest texture
    /// bins to the finest scale that fits instead of failing to allocate.
    func testFullSizeOverTheTextureLimitBinsToFit() {
        let scale = ExportPlan.scale(rawWidth: 24000, rawHeight: 6000, crop: .none, maxLongEdge: nil,
                                     maxTextureSide: 16384)
        guard case .binned(let quads) = scale else { return XCTFail("planned \(scale), not a binned render") }
        XCTAssertEqual(quads, 1)
        XCTAssertLessThanOrEqual(24000 / (2 * quads), 16384)
        XCTAssertEqual(ExportPlan.renderLongEdge(rawWidth: 24000, rawHeight: 6000, scale: scale), 12000)
    }

    /// A binned plan still too large bins further; one that fits, and any
    /// photo within the limit, is planned exactly as before.
    func testOnlyRendersPastTheLimitChange() {
        let tooBig = ExportPlan.scale(rawWidth: 100_000, rawHeight: 100, crop: .none, maxLongEdge: 20_000,
                                      maxTextureSide: 16384)
        XCTAssertLessThanOrEqual(ExportPlan.renderLongEdge(rawWidth: 100_000, rawHeight: 100, scale: tooBig), 16384)
        guard case .full = ExportPlan.scale(rawWidth: 6000, rawHeight: 4000, crop: .none, maxLongEdge: nil,
                                            maxTextureSide: 16384) else { return XCTFail("a 6000 px photo renders full") }
        guard case .binned(2) = ExportPlan.scale(rawWidth: 6000, rawHeight: 4000, crop: .none, maxLongEdge: 1200,
                                                 maxTextureSide: 16384) else { return XCTFail("binning unchanged") }
        guard case .full = ExportPlan.scale(rawWidth: 24000, rawHeight: 6000, crop: .none, maxLongEdge: nil)
        else { return XCTFail("no limit given: unchanged") }
    }

    /// High Quality Preview of a photo wider than the GPU's largest texture
    /// renders binned to fit rather than failing to allocate.
    func testHighQualityPreviewPastTheTextureLimit() throws {
        let gpu = try GPUContext()
        let width = ExportPlan.maxTextureSide(gpu.device) + 616
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("latent-hq-\(UUID().uuidString).tif")
        defer { try? FileManager.default.removeItem(at: url) }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 64))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let session = try ImageSession(file: RawFile(path: url.path), gpu: gpu)
        let layer = try HighQualityPreview.render(session, pipeline: RenderPipeline(gpu: gpu), parameters: EditParameters(),
                                                  output: .edrDisplay(headroom: 1), longEdge: 1000)
        XCTAssertEqual(layer.texture.width, 1000)
    }
}
