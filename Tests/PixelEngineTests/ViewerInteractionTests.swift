import XCTest
import Metal
@testable import PixelEngine

final class ViewerInteractionTests: XCTestCase {
    typealias VI = ViewerInteraction

    // MARK: - Press classification

    func testQuickStillPressIsAClick() {
        var p = VI.PressClassifier(location: CGPoint(x: 10, y: 10), time: 100)
        XCTAssertEqual(p.moved(to: CGPoint(x: 12, y: 12), time: 100.1), .pending)   // under 4 points
        XCTAssertEqual(p.released(at: CGPoint(x: 12, y: 12), time: 100.2), .click)
        XCTAssertFalse(VI.PressClassifier.showsMagnifier(.click))
    }

    func testStillPressHeldBecomesAHoldAndStaysOne() {
        var p = VI.PressClassifier(location: .zero, time: 0)
        XCTAssertEqual(p.update(time: 0.2), .pending)
        XCTAssertEqual(p.update(time: 0.25), .hold)
        XCTAssertEqual(p.moved(to: CGPoint(x: 100, y: 0), time: 0.5), .hold)
        XCTAssertEqual(p.released(at: CGPoint(x: 100, y: 0), time: 1), .hold)
        XCTAssertTrue(VI.PressClassifier.showsMagnifier(.hold))
    }

    func testLateReleaseWithoutTimerIsStillAHold() {
        var p = VI.PressClassifier(location: .zero, time: 0)
        XCTAssertEqual(p.released(at: .zero, time: 0.3), .hold)
    }

    func testMovingIsADragWhichAlsoShowsTheMagnifierAtFit() {
        var p = VI.PressClassifier(location: .zero, time: 0)
        XCTAssertEqual(p.moved(to: CGPoint(x: 3, y: 3), time: 0.05), .drag)   // 4.24 points
        XCTAssertEqual(p.update(time: 1), .drag)
        XCTAssertEqual(p.released(at: .zero, time: 1), .drag)
        XCTAssertTrue(VI.PressClassifier.showsMagnifier(.drag))
        XCTAssertFalse(VI.PressClassifier.showsMagnifier(.pending))
    }

    // MARK: - Wheel

    private func wheel(dx: CGFloat = 0, dy: CGFloat = 0, precise: Bool = true, inverted: Bool = false,
                       phase: VI.ScrollPhase = .none, momentum: VI.ScrollPhase = .none,
                       zoom: Bool = false, fit: Bool = true, navigates: Bool = true) -> VI.WheelEvent {
        VI.WheelEvent(precise: precise, delta: CGSize(width: dx, height: dy), invertedFromDevice: inverted,
                      phase: phase, momentumPhase: momentum, zoomModifier: zoom, atFit: fit,
                      canNavigate: navigates)
    }

    func testSidewaysSwipeAtFitStepsOncePerGesture() {
        var w = VI.WheelInterpreter()
        // Natural scrolling: the delta follows the fingers, which move left.
        XCTAssertEqual(w.interpret(wheel(dx: -20, inverted: true, phase: .began)), .none)
        XCTAssertEqual(w.interpret(wheel(dx: -20, inverted: true, phase: .changed)), .none)
        XCTAssertEqual(w.interpret(wheel(dx: -20, inverted: true, phase: .changed)), .navigate(1))
        XCTAssertEqual(w.interpret(wheel(dx: -80, inverted: true, phase: .changed)), .none, "rest of the swipe")
        XCTAssertEqual(w.interpret(wheel(inverted: true, phase: .ended)), .none)
        XCTAssertEqual(w.interpret(wheel(dx: -90, inverted: true, momentum: .changed)), .none, "momentum")
        // The next swipe works again, the other way.
        XCTAssertEqual(w.interpret(wheel(dx: 30, inverted: true, phase: .began)), .none)
        XCTAssertEqual(w.interpret(wheel(dx: 30, inverted: true, phase: .changed)), .navigate(-1))
    }

    func testSwipeDirectionFollowsTheFingersWhateverTheScrollingSetting() {
        // Without natural scrolling the delta is flipped: fingers moving
        // left report a positive delta, and still mean "next".
        var w = VI.WheelInterpreter()
        XCTAssertEqual(w.interpret(wheel(dx: 60, inverted: false, phase: .began)), .navigate(1))
        var natural = VI.WheelInterpreter()
        XCTAssertEqual(natural.interpret(wheel(dx: 60, inverted: true, phase: .began)), .navigate(-1))
    }

    func testVerticalScrollAtFitNeverSteps() {
        var w = VI.WheelInterpreter()
        XCTAssertEqual(w.interpret(wheel(dx: -10, dy: -60, phase: .began)), .none)
        // Its sideways drift, however large later, doesn't step either.
        XCTAssertEqual(w.interpret(wheel(dx: -200, phase: .changed)), .none)
    }

    func testNoSwipeNavigationWhereItIsNotAllowedOrWithAMouseWheel() {
        var w = VI.WheelInterpreter()
        XCTAssertEqual(w.interpret(wheel(dx: -80, phase: .began, navigates: false)), .none)
        XCTAssertEqual(w.interpret(wheel(dx: -8, precise: false)), .none, "a wheel at fit does nothing")
        XCTAssertEqual(w.interpret(wheel(dy: -3, precise: false)), .none)
    }

    func testMomentumAloneNeverNavigates() {
        var w = VI.WheelInterpreter()
        XCTAssertEqual(w.interpret(wheel(dx: -10, phase: .began)), .none)
        XCTAssertEqual(w.interpret(wheel(phase: .ended)), .none)
        XCTAssertEqual(w.interpret(wheel(dx: -200, momentum: .began)), .none)
    }

    func testPhaselessPreciseDevicesStepEveryFiftyPoints() {
        var w = VI.WheelInterpreter()
        XCTAssertEqual(w.interpret(wheel(dx: 30)), .none)
        XCTAssertEqual(w.interpret(wheel(dx: 30)), .navigate(1))
        XCTAssertEqual(w.interpret(wheel(dx: 30)), .none)
        XCTAssertEqual(w.interpret(wheel(dx: 30)), .navigate(1))
    }

    func testScrollingPansWhenZoomedIn() {
        var w = VI.WheelInterpreter()
        XCTAssertEqual(w.interpret(wheel(dx: 5, dy: -12, phase: .changed, fit: false)),
                       .pan(CGSize(width: 5, height: -12)))
        XCTAssertEqual(w.interpret(wheel(dy: -3, momentum: .changed, fit: false)),
                       .pan(CGSize(width: 0, height: -3)), "momentum keeps panning")
        XCTAssertEqual(w.interpret(wheel(dy: -1, precise: false, fit: false)),
                       .pan(CGSize(width: 0, height: -10)), "wheel notches are scaled up")
        XCTAssertEqual(w.interpret(wheel(dx: -80, phase: .began, fit: false)),
                       .pan(CGSize(width: -80, height: 0)), "zoomed in, a swipe pans, never steps")
    }

    func testTrackpadZoomIsSmoothLimitedAndIgnoresMomentum() {
        var w = VI.WheelInterpreter()
        XCTAssertEqual(w.interpret(wheel(dy: 100, phase: .began, zoom: true)), .zoom(2))
        XCTAssertEqual(w.interpret(wheel(dy: -50, phase: .changed, zoom: true)), .zoom(pow(2, -0.5)))
        XCTAssertEqual(w.interpret(wheel(dy: 1000, phase: .changed, zoom: true, fit: false)), .zoom(2))
        XCTAssertEqual(w.interpret(wheel(dy: 40, momentum: .changed, zoom: true)), .none)
        // Letting go of the modifier doesn't turn that gesture's momentum into a pan.
        XCTAssertEqual(w.interpret(wheel(dy: 40, momentum: .changed, fit: false)), .none)
        // A fresh gesture pans again.
        XCTAssertEqual(w.interpret(wheel(dy: 4, phase: .began, fit: false)), .pan(CGSize(width: 0, height: 4)))
    }

    func testMouseWheelZoomsOneStepPerNotchFollowingTheWheel() {
        var w = VI.WheelInterpreter()
        XCTAssertEqual(w.interpret(wheel(dy: 1, precise: false, zoom: true)), .zoom(1.25))
        XCTAssertEqual(w.interpret(wheel(dy: 7, precise: false, zoom: true)), .zoom(1.25), "a fast spin is one notch")
        XCTAssertEqual(w.interpret(wheel(dy: -1, precise: false, zoom: true)), .zoom(0.8))
        XCTAssertEqual(w.interpret(wheel(dy: 1, precise: false, inverted: true, zoom: true)), .zoom(0.8))
        XCTAssertEqual(w.interpret(wheel(dx: 3, precise: false, zoom: true)), .none)
    }

    // MARK: - Magnifier

    func testMagnifierZoomIsOnePixelPerPoint() {
        XCTAssertEqual(VI.Magnifier.zoom(backingScale: 2, viewZoom: 0.12), 2)
        XCTAssertEqual(VI.Magnifier.zoom(backingScale: 1, viewZoom: 0.12), 1)
        XCTAssertEqual(VI.Magnifier.zoom(backingScale: 2, viewZoom: 1.5), 3, "a small image still magnifies")
        XCTAssertEqual(VI.Magnifier.zoom(backingScale: 2, viewZoom: 6), ViewportTransform.maximumZoom)
    }

    func testMagnifierShowsWhatIsUnderThePointer() {
        let image = CGSize(width: 6000, height: 4000)
        let drawable = CGSize(width: 1200, height: 800)
        let fit = ViewportTransform.fit(imageSize: image, drawableSize: drawable)
        let pointer = CGPoint(x: 300, y: 200)
        let loupe = VI.Magnifier(center: pointer, radius: 220, zoom: 2)
        let under = fit.sensorPoint(forScreenPoint: pointer, drawableSize: drawable)
        let shown = loupe.transform(in: fit, drawableSize: drawable)
        XCTAssertEqual(shown.zoom, 2)
        let same = shown.sensorPoint(forScreenPoint: pointer, drawableSize: drawable)
        XCTAssertEqual(same.x, under.x, accuracy: 1e-6)
        XCTAssertEqual(same.y, under.y, accuracy: 1e-6)
        let rect = loupe.canvasRect(in: fit, drawableSize: drawable)
        XCTAssertEqual(rect.width, 220, accuracy: 1e-9)
        XCTAssertEqual(rect.midX, under.x, accuracy: 1e-9)
        XCTAssertEqual(rect.midY, under.y, accuracy: 1e-9)
    }

    func testMagnifierTileRegionKeepsItsSizeAndStaysOnTheSensor() {
        let sensor = CGSize(width: 6016, height: 4016)
        let middle = VI.Magnifier.tileRegion(covering: CGRect(x: 1000.4, y: 900.2, width: 220, height: 220),
                                             margin: 96, sensorSize: sensor)
        XCTAssertEqual(middle, CGRect(x: 904, y: 804, width: 412, height: 412))
        // Near a corner the region moves onto the sensor rather than shrinking.
        let corner = VI.Magnifier.tileRegion(covering: CGRect(x: -50, y: 3900, width: 220, height: 220),
                                             margin: 96, sensorSize: sensor)
        XCTAssertEqual(corner, CGRect(x: 0, y: 4016 - 412, width: 412, height: 412))
        // Larger than a small sensor: the whole sensor.
        let tiny = VI.Magnifier.tileRegion(covering: CGRect(x: 10, y: 10, width: 220, height: 220),
                                           margin: 96, sensorSize: CGSize(width: 300, height: 200))
        XCTAssertEqual(tiny, CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    func testSquarePixelsOnlyPastTwoHundredPercent() {
        XCTAssertFalse(VI.samplesNearest(zoom: 0.25))
        XCTAssertFalse(VI.samplesNearest(zoom: 1))
        XCTAssertFalse(VI.samplesNearest(zoom: 2))
        XCTAssertTrue(VI.samplesNearest(zoom: 2.5))
        XCTAssertTrue(VI.samplesNearest(zoom: 8))
    }

    // MARK: - GPU

    /// Past 200% each tile texel covers a block of identical screen
    /// pixels; at 200% bilinear still blends neighbours.
    func testPresentDrawsSquarePixelsPastTwoHundredPercent() throws {
        let gpu = try GPUContext()
        let presenter = Presenter(gpu: gpu)
        // 4x4 checkerboard of 0.2 and 0.8.
        var pixels: [Float] = []
        for y in 0..<4 { for x in 0..<4 { let v: Float = (x + y) % 2 == 0 ? 0.2 : 0.8; pixels += [v, v, v] } }
        let size = CGSize(width: 4, height: 4)
        let source = try XCTUnwrap(makeTexture(gpu, width: 4, height: 4, pixels: pixels))
        let layer = PresentLayer(texture: source, coverage: CGRect(origin: .zero, size: size))

        func draw(zoom: CGFloat) throws -> [Float] {
            let side = Int(4 * zoom)
            let target = try XCTUnwrap(makeTexture(gpu, width: side, height: side,
                                                   pixels: [Float](repeating: 0, count: side * side * 3)))
            let commands = try XCTUnwrap(presenter.encode(
                base: layer, tile: layer,
                transform: ViewportTransform(zoom: zoom, center: CGPoint(x: 2, y: 2)),
                frame: CropFrame(sensorSize: size), into: target,
                backgroundLevel: 0, displayHeadroom: 1))
            commands.commit()
            commands.waitUntilCompleted()
            return readRGB(target)
        }

        let four = try draw(zoom: 4)
        for y in 0..<16 {
            for x in 0..<16 {
                XCTAssertEqual(four[(y * 16 + x) * 3], pixels[((y / 4) * 4 + x / 4) * 3], accuracy: 1e-3,
                               "(\(x), \(y)) shows its texel exactly")
            }
        }
        let two = try draw(zoom: 2)
        // At a texel boundary inside the image bilinear gives a blend.
        let blended = two[(2 * 8 + 1) * 3]
        XCTAssertGreaterThan(blended, 0.25)
        XCTAssertLessThan(blended, 0.75)
    }

    /// The loupe shows its own tile inside the circle, a ring at its edge,
    /// the base layer magnified where it has no tile, and leaves the rest
    /// of the view as it was.
    func testPresentDrawsTheMagnifier() throws {
        let gpu = try GPUContext()
        let presenter = Presenter(gpu: gpu)
        let size = CGSize(width: 64, height: 64)
        let base = PresentLayer(texture: try XCTUnwrap(makeTexture(gpu, width: 64, height: 64,
                                                                  pixels: [Float](repeating: 0.3, count: 64 * 64 * 3))),
                                coverage: CGRect(origin: .zero, size: size))
        let loupeTile = PresentLayer(texture: try XCTUnwrap(makeTexture(gpu, width: 32, height: 32,
                                                                       pixels: [Float](repeating: 0.6, count: 32 * 32 * 3))),
                                     coverage: CGRect(x: 16, y: 16, width: 32, height: 32))
        let loupe = VI.Magnifier(center: CGPoint(x: 32, y: 32), radius: 20, zoom: 2)

        func draw(_ magnifier: PresentMagnifier?) throws -> [Float] {
            let target = try XCTUnwrap(makeTexture(gpu, width: 64, height: 64,
                                                   pixels: [Float](repeating: 0, count: 64 * 64 * 3)))
            let commands = try XCTUnwrap(presenter.encode(
                base: base, tile: nil, transform: .fit(imageSize: size, drawableSize: size),
                frame: CropFrame(sensorSize: size), into: target,
                backgroundLevel: 0, displayHeadroom: 1, magnifier: magnifier))
            commands.commit()
            commands.waitUntilCompleted()
            return readRGB(target)
        }
        func at(_ image: [Float], _ x: Int, _ y: Int) -> Float { image[(y * 64 + x) * 3] }

        let withTile = try draw(PresentMagnifier(loupe: loupe, ringWidth: 2, tile: loupeTile))
        XCTAssertEqual(at(withTile, 32, 32), 0.6, accuracy: 1e-3, "the loupe's tile at the centre")
        XCTAssertEqual(at(withTile, 2, 2), 0.3, accuracy: 1e-3, "the view outside")
        XCTAssertEqual(at(withTile, 32 + 18, 32), 0.8, accuracy: 0.05, "the ring")

        let withoutTile = try draw(PresentMagnifier(loupe: loupe, ringWidth: 2, tile: nil))
        XCTAssertEqual(at(withoutTile, 32, 32), 0.3, accuracy: 1e-3, "the base, magnified, until the tile comes")

        let none = try draw(nil)
        XCTAssertEqual(at(none, 32, 32), 0.3, accuracy: 1e-3)
        XCTAssertEqual(at(none, 50, 32), 0.3, accuracy: 1e-3)
    }

    private func makeTexture(_ gpu: GPUContext, width: Int, height: Int, pixels rgb: [Float]) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = gpu.device.makeTexture(descriptor: descriptor) else { return nil }
        var half = [Float16](repeating: 1, count: width * height * 4)
        for i in 0..<width * height {
            for c in 0..<3 { half[i * 4 + c] = Float16(rgb[i * 3 + c]) }
        }
        half.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                            withBytes: $0.baseAddress!, bytesPerRow: width * 8)
        }
        return texture
    }

    private func readRGB(_ texture: MTLTexture) -> [Float] {
        var half = [Float16](repeating: 0, count: texture.width * texture.height * 4)
        half.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return (0..<texture.width * texture.height).flatMap { i in (0..<3).map { Float(half[i * 4 + $0]) } }
    }
}
