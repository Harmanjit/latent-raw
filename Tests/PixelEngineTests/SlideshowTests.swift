import XCTest
import Metal
@testable import PixelEngine

final class SlideshowTests: XCTestCase {
    // MARK: - Geometry

    func testFitRectCentresAndFillsWhicheverWayIsTighter() {
        let view = CGSize(width: 2880, height: 1800)
        XCTAssertEqual(SlideshowGeometry.fitRect(imageSize: CGSize(width: 2700, height: 1800), viewSize: view),
                       CGRect(x: 90, y: 0, width: 2700, height: 1800))
        // Portrait: pillarboxed.
        XCTAssertEqual(SlideshowGeometry.fitRect(imageSize: CGSize(width: 1200, height: 1800), viewSize: view),
                       CGRect(x: 840, y: 0, width: 1200, height: 1800))
        // A slide a little short of the screen still fills it.
        XCTAssertEqual(SlideshowGeometry.fitRect(imageSize: CGSize(width: 1350, height: 900), viewSize: view),
                       CGRect(x: 90, y: 0, width: 2700, height: 1800))
        XCTAssertEqual(SlideshowGeometry.fitRect(imageSize: .zero, viewSize: view), .zero)
    }

    func testPushMovesBothSlidesAScreenAlongTheDirectionOfTravel() throws {
        let view = CGSize(width: 1000, height: 500)
        let image = CGSize(width: 1000, height: 500)
        func rects(_ t: CGFloat, _ direction: SlideshowDirection) -> (CGRect?, CGRect?) {
            let r = SlideshowGeometry.rects(transition: .push, progress: t, direction: direction,
                                            fromImage: image, toImage: image, viewSize: view)
            return (r.from, r.to)
        }
        XCTAssertEqual(rects(0, .forward).0?.minX, 0)
        XCTAssertEqual(rects(0, .forward).1?.minX, 1000, "the new slide starts off the right edge")
        XCTAssertEqual(rects(0.5, .forward).0?.minX, -500)
        XCTAssertEqual(rects(0.5, .forward).1?.minX, 500)
        XCTAssertEqual(rects(1, .forward).1?.minX, 0)
        XCTAssertEqual(rects(0.5, .backward).1?.minX, -500, "going back it comes from the left")
    }

    func testZoomGrowsTheOldSlideAndSettlesTheNew() throws {
        let view = CGSize(width: 1000, height: 500)
        let image = CGSize(width: 1000, height: 500)
        let start = SlideshowGeometry.rects(transition: .zoom, progress: 0, direction: .forward,
                                            fromImage: image, toImage: image, viewSize: view)
        let end = SlideshowGeometry.rects(transition: .zoom, progress: 1, direction: .forward,
                                          fromImage: image, toImage: image, viewSize: view)
        XCTAssertEqual(try XCTUnwrap(start.to).width, 900, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(end.from).width, 1300, accuracy: 1e-9)
        XCTAssertEqual(end.to, CGRect(x: 0, y: 0, width: 1000, height: 500))
        XCTAssertEqual(try XCTUnwrap(end.from).midX, 500, accuracy: 1e-9, "scaled about the centre")
    }

    func testCrossFadeAndCutLeaveTheRectanglesAlone() {
        let view = CGSize(width: 1000, height: 500)
        for transition in [SlideshowTransition.cut, .crossFade, .fadeThroughBlack] {
            let r = SlideshowGeometry.rects(transition: transition, progress: 0.4, direction: .forward,
                                            fromImage: view, toImage: view, viewSize: view)
            XCTAssertEqual(r.from, CGRect(origin: .zero, size: view))
            XCTAssertEqual(r.to, CGRect(origin: .zero, size: view))
        }
    }

    /// The slide fits the screen; the whole frame renders large enough that
    /// the crop still covers it, which is what the scale is chosen from.
    func testRenderPlanAccountsForCropAndRotation() {
        let sensor = CGSize(width: 6000, height: 4000)
        let screen = CGSize(width: 2880, height: 1800)
        var plan = SlideshowGeometry.renderPlan(sensor: sensor, canvas: sensor, screen: screen)
        XCTAssertEqual(plan.slideLongEdge, 2700)
        XCTAssertEqual(plan.sensorLongEdge, 2700)

        // Half the frame cropped: the frame must render at twice the slide.
        plan = SlideshowGeometry.renderPlan(sensor: sensor, canvas: CGSize(width: 3000, height: 2000), screen: screen)
        XCTAssertEqual(plan.slideLongEdge, 2700)
        XCTAssertEqual(plan.sensorLongEdge, 5400)

        // Portrait on a landscape screen: height limits it.
        plan = SlideshowGeometry.renderPlan(sensor: sensor, canvas: CGSize(width: 4000, height: 6000), screen: screen)
        XCTAssertEqual(plan.slideLongEdge, 1800)
        XCTAssertEqual(plan.sensorLongEdge, 1800)

        // A crop smaller than the screen is never enlarged.
        plan = SlideshowGeometry.renderPlan(sensor: sensor, canvas: CGSize(width: 900, height: 600), screen: screen)
        XCTAssertEqual(plan.slideLongEdge, 900)
        XCTAssertEqual(plan.sensorLongEdge, 6000)
    }

    func testReduceMotionKeepsOnlyTransitionsThatDoNotMove() {
        XCTAssertEqual(SlideshowTransition.push.reducingMotion(true), .crossFade)
        XCTAssertEqual(SlideshowTransition.zoom.reducingMotion(true), .crossFade)
        XCTAssertEqual(SlideshowTransition.cut.reducingMotion(true), .cut)
        XCTAssertEqual(SlideshowTransition.fadeThroughBlack.reducingMotion(true), .fadeThroughBlack)
        XCTAssertEqual(SlideshowTransition.push.reducingMotion(false), .push)
    }

    func testEasingIsSymmetricAndClamped() {
        XCTAssertEqual(SlideshowEasing.easeInOut(0), 0)
        XCTAssertEqual(SlideshowEasing.easeInOut(0.5), 0.5)
        XCTAssertEqual(SlideshowEasing.easeInOut(1), 1)
        XCTAssertEqual(SlideshowEasing.easeInOut(2), 1)
        XCTAssertEqual(SlideshowEasing.easeInOut(0.25) + SlideshowEasing.easeInOut(0.75), 1, accuracy: 1e-6)
    }

    // MARK: - Drawing

    private func solid(_ gpu: GPUContext, _ value: UInt8, width: Int = 8, height: Int = 8) throws -> SlideTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                         mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        let texture = try XCTUnwrap(gpu.device.makeTexture(descriptor: d))
        var bytes = [UInt8](repeating: value, count: width * height * 4)
        for i in stride(from: 3, to: bytes.count, by: 4) { bytes[i] = 255 }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: &bytes,
                        bytesPerRow: width * 4)
        return SlideTexture(texture: texture)
    }

    /// Draws `frame` into a 100x50 half-float target and returns the red
    /// channel at each requested pixel.
    private func draw(_ frame: SlideshowFrame, gpu: GPUContext, at points: [(Int, Int)]) throws -> [Float] {
        let (w, h) = (100, 50)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: SlideshowRenderer.pixelFormat,
                                                         width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = try XCTUnwrap(gpu.device.makeTexture(descriptor: d))
        try SlideshowRenderer(gpu: gpu).draw(frame, into: target)
        var pixels = [Float16](repeating: 0, count: w * h * 4)
        target.getBytes(&pixels, bytesPerRow: w * 8, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        return points.map { Float(pixels[($0.1 * w + $0.0) * 4]) }
    }

    private func decode(_ encoded: Float) -> Float {
        encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
    }

    func testCrossFadeMixesInLinearLight() throws {
        let gpu = try GPUContext()
        let grey = try solid(gpu, 128, width: 100, height: 50), white = try solid(gpu, 255, width: 100, height: 50)
        let mid = try draw(SlideshowFrame(from: grey, to: white, transition: .crossFade, progress: 0.5),
                           gpu: gpu, at: [(50, 25)])
        XCTAssertEqual(mid[0], (decode(128 / 255) + 1) / 2, accuracy: 0.005)
        let start = try draw(SlideshowFrame(from: grey, to: white, transition: .crossFade, progress: 0),
                             gpu: gpu, at: [(50, 25)])
        XCTAssertEqual(start[0], decode(128 / 255), accuracy: 0.005)
    }

    func testPushShowsTheOldSlideBehindTheLeadingEdge() throws {
        let gpu = try GPUContext()
        let black = try solid(gpu, 0, width: 100, height: 50), white = try solid(gpu, 255, width: 100, height: 50)
        let forward = try draw(SlideshowFrame(from: black, to: white, transition: .push, progress: 0.5),
                               gpu: gpu, at: [(25, 25), (75, 25)])
        XCTAssertEqual(forward[0], 0, accuracy: 0.01)
        XCTAssertEqual(forward[1], 1, accuracy: 0.01)
        let backward = try draw(SlideshowFrame(from: black, to: white, transition: .push, progress: 0.5,
                                               direction: .backward),
                                gpu: gpu, at: [(25, 25), (75, 25)])
        XCTAssertEqual(backward[0], 1, accuracy: 0.01)
        XCTAssertEqual(backward[1], 0, accuracy: 0.01)
    }

    func testAStillIsFittedOnBlack() throws {
        let gpu = try GPUContext()
        // Square slide on a 2:1 view: 50 px wide in the middle.
        let white = try solid(gpu, 255, width: 10, height: 10)
        let values = try draw(.still(white), gpu: gpu, at: [(10, 25), (50, 25), (90, 25)])
        XCTAssertEqual(values, [0, 1, 0])
        let cut = try draw(SlideshowFrame(from: try solid(gpu, 0), to: white, transition: .cut, progress: 0.2),
                           gpu: gpu, at: [(50, 25)])
        XCTAssertEqual(cut[0], 1, accuracy: 0.001, "a cut shows the new slide at once")
        let throughBlack = try draw(SlideshowFrame(from: white, to: white, transition: .fadeThroughBlack,
                                                   progress: 0.5), gpu: gpu, at: [(50, 25)])
        XCTAssertEqual(throughBlack[0], 0, accuracy: 0.001)
    }
}
