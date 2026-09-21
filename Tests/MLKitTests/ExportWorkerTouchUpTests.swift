import XCTest
import os
import CoreGraphics
import simd
import RawCore
import PixelEngine
@testable import MLKit

/// Exports carry the touch-up (docs/Retouch.md §9): the page render of
/// the portrait fixture with Skin Smoothing at 100 differs from one at 0
/// inside the face and nowhere else, which needs the region masks built
/// again for the export's own session. Skipped without the fixture.
final class ExportWorkerTouchUpTests: XCTestCase {
    /// The rendered pixels as RGBX bytes, with the row stride.
    private func bytes(_ image: CGImage) throws -> (data: Data, rowBytes: Int) {
        XCTAssertEqual(image.bitsPerPixel, 32)
        return (try XCTUnwrap(image.dataProvider?.data as Data?), image.bytesPerRow)
    }

    func testSkinSmoothingChangesTheFaceAndNothingElse() async throws {
        let url = try PortraitFixture.dngURL()
        let gpu = try GPUContext()

        // The faces, as Find Faces stores them.
        let session = try ImageSession(file: try RawFile(path: url.path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        let parameters = try ExportPlan.parameters(editStackJSON: nil, session: session, colorSpace: .sRGB)
        let render = try TouchUpAnalysis.render(session: session, pipeline: pipeline, gpu: gpu, parameters: parameters,
                                                rotation: ExportPlan.rotation(for: session.file.summary, userRotation: 0))
        let found = TouchUpRegions.find(in: render, session: session, pipeline: pipeline, parameters: parameters)
        XCTAssertEqual(found.faces.count, 1)
        let box = try XCTUnwrap(found.faces.first).boundingBox

        func json(skinSmoothing: Float) throws -> String {
            var p = EditParameters()
            p.touchUp.faces = found.faces
            p.touchUp.skinSmoothing = skinSmoothing
            p.touchUp.modelVersion = FaceLandmarker.modelVersion
            return try EditStack(parameters: p).encodeJSON()
        }
        func rendered(skinSmoothing: Float) async throws -> CGImage {
            let request = ExportWorker.ImageRequest(sourceURL: url, editStackJSON: try json(skinSmoothing: skinSmoothing),
                                                    userRotation: 0, colorSpace: .sRGB, maxLongEdge: 1500,
                                                    bitsPerComponent: 8, runsAIDenoise: false)
            return try await ExportWorker.renderImage(request, gpu: gpu).cgImage
        }
        let plain = try await rendered(skinSmoothing: 0)
        let smoothed = try await rendered(skinSmoothing: 100)
        XCTAssertEqual(plain.width, smoothed.width)
        XCTAssertEqual(plain.height, smoothed.height)

        // The face on the export's grid (no lens profile, so raw is output),
        // and a looser box holding the forehead arc and the blur's reach.
        let width = plain.width, height = plain.height
        let face = CGRect(x: CGFloat(box.x) * CGFloat(width), y: CGFloat(box.y) * CGFloat(height),
                          width: CGFloat(box.z) * CGFloat(width), height: CGFloat(box.w) * CGFloat(height))
        let loose = face.insetBy(dx: -face.width * 0.3, dy: -face.height * 0.4)
        let a = try bytes(plain), b = try bytes(smoothed)
        var insideSum = 0, insideCount = 0, outsideSum = 0, outsideCount = 0, outsideMax = 0
        a.data.withUnsafeBytes { pa in
            b.data.withUnsafeBytes { pb in
                for y in 0..<height {
                    for x in 0..<width {
                        let i = y * a.rowBytes + x * 4, j = y * b.rowBytes + x * 4
                        var d = 0
                        for c in 0..<3 { d += abs(Int(pa[i + c]) - Int(pb[j + c])) }
                        let p = CGPoint(x: x, y: y)
                        if face.contains(p) {
                            insideSum += d; insideCount += 1
                        } else if !loose.contains(p) {
                            outsideSum += d; outsideCount += 1; outsideMax = max(outsideMax, d)
                        }
                    }
                }
            }
        }
        let inside = Double(insideSum) / Double(max(insideCount, 1))
        let outside = Double(outsideSum) / Double(max(outsideCount, 1))
        print(String(format: "Touch-up export: mean change inside the face %.3f, outside %.4f (max %d), %dx%d",
                     inside, outside, outsideMax, width, height))
        XCTAssertGreaterThan(insideCount, 10_000)
        XCTAssertGreaterThan(outsideCount, 10_000)
        XCTAssertGreaterThan(inside, 0.2, "the smoothing shows on the face")
        XCTAssertLessThan(outside, 0.01, "nothing changes away from the face")
        XCTAssertLessThanOrEqual(outsideMax, 1, "a rounding flip at most")
    }

    /// The touch-up regeneration is a no-op for an edit without faces or
    /// with the sliders at zero, and the session says so.
    func testNoMasksWithoutAFaceAndASlider() throws {
        let url = try PortraitFixture.dngURL()
        let gpu = try GPUContext()
        let session = try ImageSession(file: try RawFile(path: url.path), gpu: gpu)
        let pipeline = RenderPipeline(gpu: gpu)
        var parameters = try ExportPlan.parameters(editStackJSON: nil, session: session, colorSpace: .sRGB)
        parameters.touchUp.skinSmoothing = 50
        let rotation = ExportPlan.rotation(for: session.file.summary, userRotation: 0)
        try ExportWorker.regenerateTouchUpMasks(parameters, session: session, pipeline: pipeline, gpu: gpu,
                                                rotation: rotation, name: "portrait.dng", logger: .init(.disabled))
        XCTAssertFalse(session.hasTouchUpMasks, "a slider with no face wants no masks")
        parameters.touchUp.faces = [TouchUpFace(boundingBox: SIMD4(0.3, 0.2, 0.4, 0.4))]
        parameters.touchUp.skinSmoothing = 0
        try ExportWorker.regenerateTouchUpMasks(parameters, session: session, pipeline: pipeline, gpu: gpu,
                                                rotation: rotation, name: "portrait.dng", logger: .init(.disabled))
        XCTAssertFalse(session.hasTouchUpMasks, "a face with the sliders at zero wants no masks")
        parameters.touchUp.skinSmoothing = 30
        try ExportWorker.regenerateTouchUpMasks(parameters, session: session, pipeline: pipeline, gpu: gpu,
                                                rotation: rotation, name: "portrait.dng", logger: .init(.disabled))
        XCTAssertTrue(session.hasTouchUpMasks)
    }
}
