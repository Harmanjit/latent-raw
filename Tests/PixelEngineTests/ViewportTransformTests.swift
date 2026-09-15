import XCTest
@testable import PixelEngine

/// Pure maths, no GPU: these run on any machine and pin down the
/// behaviour the gestures rely on.
final class ViewportTransformTests: XCTestCase {
    let image = CGSize(width: 6032, height: 4032)      // D750
    let drawable = CGSize(width: 2560, height: 1600)

    func testFitShowsWholeImageCentred() {
        let t = ViewportTransform.fit(imageSize: image, drawableSize: drawable)
        // A 3:2 photo in a 16:10 view is limited by height: 1600/4032 is
        // smaller than 2560/6032, so the image fills the height and has
        // bands left and right.
        XCTAssertEqual(t.zoom, 1600.0 / 4032.0, accuracy: 1e-9)
        XCTAssertEqual(t.center, CGPoint(x: 3016, y: 2016))

        let rect = t.screenRect(forSensorRect: CGRect(origin: .zero, size: image),
                                drawableSize: drawable)
        XCTAssertEqual(rect.minY, 0, accuracy: 1e-6)
        XCTAssertEqual(rect.height, 1600, accuracy: 1e-6)
        XCTAssertEqual(rect.minX, (2560 - rect.width) / 2, accuracy: 1e-6)
        XCTAssertTrue(t.isFit(imageSize: image, drawableSize: drawable))
    }

    func testScreenAndSensorMappingsAreInverses() {
        let t = ViewportTransform(zoom: 1.7, center: CGPoint(x: 1234, y: 987))
        let screen = CGPoint(x: 300, y: 1400)
        let sensor = t.sensorPoint(forScreenPoint: screen, drawableSize: drawable)
        let back = t.screenPoint(forSensorPoint: sensor, drawableSize: drawable)
        XCTAssertEqual(back.x, screen.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, screen.y, accuracy: 1e-9)
    }

    func testZoomAboutPointKeepsThatPointStill() {
        let t = ViewportTransform.fit(imageSize: image, drawableSize: drawable)
        let cursor = CGPoint(x: 400, y: 1100)
        let before = t.sensorPoint(forScreenPoint: cursor, drawableSize: drawable)

        let zoomed = t.zoomed(by: 3, about: cursor, drawableSize: drawable)
        let after = zoomed.sensorPoint(forScreenPoint: cursor, drawableSize: drawable)

        XCTAssertEqual(zoomed.zoom, t.zoom * 3, accuracy: 1e-9)
        XCTAssertEqual(after.x, before.x, accuracy: 1e-6)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-6)
    }

    func testPanMovesContentWithTheFinger() {
        let t = ViewportTransform(zoom: 2, center: CGPoint(x: 3000, y: 2000))
        // Drag 100px right, 50px down: the centre moves the other way,
        // by half as much because each screen pixel is half a sensor pixel.
        let p = t.panned(byScreenDelta: CGSize(width: 100, height: 50))
        XCTAssertEqual(p.center.x, 2950, accuracy: 1e-9)
        XCTAssertEqual(p.center.y, 1975, accuracy: 1e-9)
    }

    func testClampNeverZoomsBelowFitOrAboveMax() {
        let tiny = ViewportTransform(zoom: 0.01, center: CGPoint(x: 3016, y: 2016))
            .clamped(imageSize: image, drawableSize: drawable)
        XCTAssertEqual(tiny.zoom, ViewportTransform.fitZoom(imageSize: image, drawableSize: drawable),
                       accuracy: 1e-9)

        let huge = ViewportTransform(zoom: 50, center: CGPoint(x: 3016, y: 2016))
            .clamped(imageSize: image, drawableSize: drawable)
        XCTAssertEqual(huge.zoom, ViewportTransform.maximumZoom, accuracy: 1e-9)
    }

    func testClampKeepsImageEdgesAtOrBeyondViewEdges() {
        // At 100%, try to centre on the top-left corner: the view would
        // show empty space above and left. Clamp pulls the centre in so
        // the image's edge sits exactly at the view's edge.
        let t = ViewportTransform(zoom: 1, center: .zero)
            .clamped(imageSize: image, drawableSize: drawable)
        XCTAssertEqual(t.center.x, 1280, accuracy: 1e-9)
        XCTAssertEqual(t.center.y, 800, accuracy: 1e-9)

        let visible = t.visibleSensorRect(drawableSize: drawable)
        XCTAssertEqual(visible.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(visible.minY, 0, accuracy: 1e-9)
    }

    func testClampCentresAxisWhenImageIsSmallerThanView() {
        // Zoomed to fit width, the image is shorter than the view; any
        // vertical pan should snap back to centred.
        let fit = ViewportTransform.fit(imageSize: image, drawableSize: drawable)
        let nudged = ViewportTransform(zoom: fit.zoom, center: CGPoint(x: 3016, y: 100))
            .clamped(imageSize: image, drawableSize: drawable)
        XCTAssertEqual(nudged.center.y, 2016, accuracy: 1e-9)
    }

    // MARK: - Relative view (Compare)

    func testRelativeViewCarriesZoomAndCentreAcrossImageSizes() {
        let view = CGSize(width: 1000, height: 800)
        let big = CGSize(width: 6000, height: 4000)    // fits at 1/6
        let small = CGSize(width: 3000, height: 2000)  // fits at 1/3

        // 100% on the big image, looking at its upper-left quarter point.
        let transform = ViewportTransform(zoom: 1, center: CGPoint(x: 1500, y: 1000))
        let relative = RelativeView(transform: transform, isFit: false, imageSize: big, drawableSize: view)
        XCTAssertFalse(relative.isFit)
        XCTAssertEqual(relative.zoomFactor, 6, accuracy: 1e-9)
        XCTAssertEqual(relative.center, CGPoint(x: 0.25, y: 0.25))

        // The same image in the same view comes back unchanged.
        let same = relative.transform(imageSize: big, drawableSize: view)
        XCTAssertEqual(same.zoom, 1, accuracy: 1e-9)
        XCTAssertEqual(same.center, transform.center)

        // A half-size photo: six times its fit is 200%, at the same place.
        let other = relative.transform(imageSize: small, drawableSize: view)
        XCTAssertEqual(other.zoom, 2, accuracy: 1e-9)
        XCTAssertEqual(other.center, CGPoint(x: 750, y: 500))

        // Both panes then show the same fraction of their images.
        let bigVisible = same.visibleSensorRect(drawableSize: view)
        let smallVisible = other.visibleSensorRect(drawableSize: view)
        XCTAssertEqual(bigVisible.minX / big.width, smallVisible.minX / small.width, accuracy: 1e-9)
        XCTAssertEqual(bigVisible.width / big.width, smallVisible.width / small.width, accuracy: 1e-9)
    }

    func testRelativeViewFollowsACropAndARotation() {
        let view = CGSize(width: 1200, height: 800)
        let landscape = CGSize(width: 6000, height: 4000)
        // The other pane shows the same shot cropped tighter and turned a
        // quarter: its canvas is a different shape and size.
        let croppedPortrait = CGSize(width: 2400, height: 3600)

        let t = ViewportTransform(zoom: 0.5, center: CGPoint(x: 4500, y: 1000))
        let relative = RelativeView(transform: t, isFit: false, imageSize: landscape, drawableSize: view)
        let fitA = ViewportTransform.fitZoom(imageSize: landscape, drawableSize: view)
        XCTAssertEqual(relative.zoomFactor, 0.5 / fitA, accuracy: 1e-9)

        let other = relative.transform(imageSize: croppedPortrait, drawableSize: view)
        let fitB = ViewportTransform.fitZoom(imageSize: croppedPortrait, drawableSize: view)
        XCTAssertEqual(other.zoom / fitB, relative.zoomFactor, accuracy: 1e-9)
        XCTAssertEqual(other.center.x, 0.75 * 2400, accuracy: 1e-9)
        XCTAssertEqual(other.center.y, 0.25 * 3600, accuracy: 1e-9)

        // Carried back, the first pane lands where it started.
        let back = RelativeView(transform: other, isFit: false, imageSize: croppedPortrait, drawableSize: view)
            .transform(imageSize: landscape, drawableSize: view)
        XCTAssertEqual(back.zoom, t.zoom, accuracy: 1e-9)
        XCTAssertEqual(back.center.x, t.center.x, accuracy: 1e-6)
        XCTAssertEqual(back.center.y, t.center.y, accuracy: 1e-6)
    }

    func testFittedRelativeViewStaysFitted() {
        let view = CGSize(width: 1000, height: 800)
        let big = CGSize(width: 6000, height: 4000)
        let small = CGSize(width: 3000, height: 2000)
        let fitted = RelativeView(transform: .fit(imageSize: big, drawableSize: view), isFit: true,
                                  imageSize: big, drawableSize: view)
        XCTAssertEqual(fitted, .fit)
        XCTAssertEqual(fitted.transform(imageSize: small, drawableSize: view),
                       .fit(imageSize: small, drawableSize: view))

        // A pane that hasn't been laid out, or has no image, has nothing
        // to share but fit, and never divides by zero.
        let unsized = RelativeView(transform: ViewportTransform(zoom: 2, center: .zero), isFit: false,
                                   imageSize: big, drawableSize: .zero)
        XCTAssertEqual(unsized, .fit)
        let empty = RelativeView(transform: ViewportTransform(zoom: 2, center: .zero), isFit: false,
                                 imageSize: .zero, drawableSize: view)
        XCTAssertEqual(empty, .fit)
    }
}
