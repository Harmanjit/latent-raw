import Foundation
import CoreGraphics

/// What mouse, trackpad and wheel events mean on the image, kept free of
/// AppKit so it can be tested without a window. Ported from minivu's
/// CanvasInteraction and fitted to Latent's viewport.
///
/// The image view turns NSEvents into these plain values, asks what they
/// mean, and hands the answer to the model. Everything that could be wrong
/// about "what should this gesture do" lives here.
public enum ViewerInteraction {
    // MARK: - Click, hold or drag

    /// What a mouse press has turned out to be so far.
    public enum Press: Equatable, Sendable {
        /// Too early to tell.
        case pending
        /// Released quickly without moving.
        case click
        /// Held still.
        case hold
        /// Moved.
        case drag
    }

    /// Classifies one mouse press from its events.
    ///
    /// A press is a click until proven otherwise; holding still for
    /// `holdDelay` makes it a hold, moving further than `dragDistance` makes
    /// it a drag. Once a press is a hold or a drag it stays one, so the
    /// magnifier doesn't turn into something else when the hand trembles.
    public struct PressClassifier: Sendable {
        /// Longer than a click takes, shorter than a deliberate hold.
        public static let holdDelay: TimeInterval = 0.25
        /// In points: small enough to feel immediate, large enough that a
        /// click on a trackpad doesn't register as a drag.
        public static let dragDistance: CGFloat = 4

        public let start: CGPoint
        public let startTime: TimeInterval
        public private(set) var state: Press = .pending

        public init(location: CGPoint, time: TimeInterval) {
            start = location
            startTime = time
        }

        /// The hold timer fired, or any other chance to check the clock.
        @discardableResult
        public mutating func update(time: TimeInterval) -> Press {
            if state == .pending, time - startTime >= Self.holdDelay { state = .hold }
            return state
        }

        /// The pointer moved while the button is down.
        @discardableResult
        public mutating func moved(to location: CGPoint, time: TimeInterval) -> Press {
            guard state == .pending else { return state }
            if hypot(location.x - start.x, location.y - start.y) > Self.dragDistance {
                state = .drag
            } else {
                update(time: time)
            }
            return state
        }

        /// The button went up: the final answer (never `.pending`).
        public mutating func released(at location: CGPoint, time: TimeInterval) -> Press {
            moved(to: location, time: time)
            if state == .pending { state = time - startTime >= Self.holdDelay ? .hold : .click }
            return state
        }

        /// At fit a drag has nothing to pan, so a press shows the magnifier
        /// as soon as it is either held or moved; only a click (or the first
        /// half of a double-click) never does.
        public static func showsMagnifier(_ press: Press) -> Bool {
            press == .hold || press == .drag
        }
    }

    // MARK: - Scroll wheel and trackpad scrolling

    /// Mirror of NSEvent.Phase, reduced to what matters here.
    public enum ScrollPhase: Sendable {
        /// Not part of a gesture (a mouse wheel), or no momentum.
        case none
        case began
        case changed
        case ended
    }

    /// One scroll event, as plain values.
    public struct WheelEvent: Sendable {
        /// Trackpads and Magic Mouse report precise, point-level deltas;
        /// mouse wheels report lines per notch.
        public var precise: Bool
        /// Scrolling deltas as AppKit reports them (points when precise).
        public var delta: CGSize
        /// True when the system's natural scrolling flipped `delta`.
        public var invertedFromDevice: Bool
        public var phase: ScrollPhase
        public var momentumPhase: ScrollPhase
        /// Option or Command held: the wheel zooms.
        public var zoomModifier: Bool
        /// The whole image is in view, so there is nothing to pan.
        public var atFit: Bool
        /// A sideways swipe may step to another image here (Loupe and
        /// Develop with no tool armed).
        public var canNavigate: Bool

        public init(precise: Bool, delta: CGSize, invertedFromDevice: Bool = false,
                    phase: ScrollPhase = .none, momentumPhase: ScrollPhase = .none,
                    zoomModifier: Bool = false, atFit: Bool = false, canNavigate: Bool = false) {
            self.precise = precise
            self.delta = delta
            self.invertedFromDevice = invertedFromDevice
            self.phase = phase
            self.momentumPhase = momentumPhase
            self.zoomModifier = zoomModifier
            self.atFit = atFit
            self.canNavigate = canNavigate
        }
    }

    public enum WheelOutcome: Equatable, Sendable {
        /// Show the image `offset` places away (+1 next, -1 previous).
        case navigate(Int)
        /// Multiply the zoom by this factor, about the pointer.
        case zoom(CGFloat)
        /// Move the content by this many points (content follows the delta).
        case pan(CGSize)
        case none
    }

    /// Turns scroll events into navigation, zoom or pan.
    ///
    /// Stateful because a trackpad swipe is dozens of small events: they
    /// add up to one step to the next photo, and the rest of that swipe
    /// (and its momentum) must not flip through the folder; a zooming
    /// gesture's momentum must not keep zooming after the fingers lift.
    public struct WheelInterpreter: Sendable {
        /// Sideways travel in points that turns a swipe into one image step.
        public static let navigationDistance: CGFloat = 50
        /// Zoom factor per mouse wheel notch.
        public static let wheelZoomStep: CGFloat = 1.25
        /// Zoom doubles for every this many points of trackpad travel.
        public static let pointsPerDoubling: CGFloat = 100
        /// Mouse wheel notches aren't points; this scales them to a pan
        /// that feels like a scroll.
        public static let wheelPanGain: CGFloat = 10

        private var accumulated: CGSize = .zero
        /// This gesture has already stepped an image, or turned out to be
        /// a vertical scroll: the rest of it does nothing at fit.
        private var navigationSpent = false
        /// This gesture zoomed, so its momentum is ignored even once the
        /// modifier is let go.
        private var gestureZoomed = false

        public init() {}

        public mutating func interpret(_ e: WheelEvent) -> WheelOutcome {
            if e.precise, e.phase == .began {
                accumulated = .zero
                navigationSpent = false
                gestureZoomed = false
            }
            let momentum = e.momentumPhase != .none

            if e.zoomModifier {
                // Momentum would keep zooming after the fingers lift.
                guard !momentum else { return .none }
                if e.precise {
                    guard e.delta.height != 0 else { return .none }
                    if e.phase != .none { gestureZoomed = true }
                    let factor = pow(2, e.delta.height / Self.pointsPerDoubling)
                    return .zoom(min(max(factor, 0.5), 2))
                }
                // A mouse wheel: one step per notch whatever its size (fast
                // spins report bigger deltas), following the physical wheel
                // so rolling away always zooms in, natural scrolling or not.
                let dy = e.invertedFromDevice ? -e.delta.height : e.delta.height
                guard dy != 0 else { return .none }
                return .zoom(dy > 0 ? Self.wheelZoomStep : 1 / Self.wheelZoomStep)
            }
            if momentum && gestureZoomed { return .none }

            // Zoomed in: scrolling moves around the image, momentum included.
            if !e.atFit {
                guard e.delta != .zero else { return .none }
                return .pan(e.precise ? e.delta
                            : CGSize(width: e.delta.width * Self.wheelPanGain,
                                     height: e.delta.height * Self.wheelPanGain))
            }

            // At fit: a sideways trackpad swipe steps once per gesture. A
            // mouse wheel does nothing here, as it did before.
            guard e.precise, e.canNavigate, !momentum, !navigationSpent else { return .none }
            accumulated.width += e.delta.width
            accumulated.height += e.delta.height
            let across = abs(accumulated.width), down = abs(accumulated.height)
            if down >= Self.navigationDistance, down > across {
                // A vertical scroll: don't let its sideways drift step later.
                if e.phase != .none { navigationSpent = true }
                accumulated = .zero
                return .none
            }
            guard across >= Self.navigationDistance, across > down else { return .none }
            // The fingers' own direction, whatever the scrolling setting:
            // fingers moving left bring the next image in, as in Photos.
            let fingers = e.invertedFromDevice ? accumulated.width : -accumulated.width
            accumulated = .zero
            // Devices without phases never end a gesture, so they get one
            // step per 50 points instead of one per swipe.
            if e.phase != .none { navigationSpent = true }
            return .navigate(fingers < 0 ? 1 : -1)
        }
    }

    // MARK: - Magnifier

    /// The round loupe shown while the mouse button is held on a fitted
    /// image. Everything is in drawable pixels, like `ViewportTransform`.
    public struct Magnifier: Equatable, Sendable {
        /// Radius in points; scaled by the backing scale for drawing.
        public static let radiusPoints: CGFloat = 110

        /// Where the pointer is.
        public var center: CGPoint
        public var radius: CGFloat
        /// Drawable pixels per canvas pixel inside the loupe.
        public var zoom: CGFloat

        public init(center: CGPoint, radius: CGFloat, zoom: CGFloat) {
            self.center = center
            self.radius = radius
            self.zoom = zoom
        }

        /// One image pixel per point: 100% on an ordinary screen, 200% on
        /// Retina. Always at least twice the view's zoom so it magnifies a
        /// small image too, and never past the viewport's limit.
        public static func zoom(backingScale: CGFloat, viewZoom: CGFloat) -> CGFloat {
            min(max(backingScale, viewZoom * 2), ViewportTransform.maximumZoom)
        }

        /// The transform inside the loupe: the view's, zoomed about the
        /// pointer, so the loupe shows what is under the pointer.
        public func transform(in viewport: ViewportTransform, drawableSize: CGSize) -> ViewportTransform {
            viewport.zoomed(by: zoom / viewport.zoom, about: center, drawableSize: drawableSize)
        }

        /// The canvas rectangle the loupe's square bounds show.
        public func canvasRect(in viewport: ViewportTransform, drawableSize: CGSize) -> CGRect {
            let centre = viewport.sensorPoint(forScreenPoint: center, drawableSize: drawableSize)
            let half = radius / zoom
            return CGRect(x: centre.x - half, y: centre.y - half, width: 2 * half, height: 2 * half)
        }

        /// The sensor region to render for the loupe: `needed` grown by
        /// `margin` so small moves stay inside it, snapped to whole pixels,
        /// and moved (not shrunk) to lie on the sensor. Keeping the size
        /// constant as the pointer moves lets every render reuse the same
        /// pooled textures. A size equal to `avoiding` (the view's own tile)
        /// grows by a pixel, since pooled textures are keyed by size and the
        /// loupe's render must never draw into the tile on screen.
        public static func tileRegion(covering needed: CGRect, margin: CGFloat, sensorSize: CGSize,
                                      avoiding: CGSize = .zero) -> CGRect {
            let sensorW = sensorSize.width.rounded(.down), sensorH = sensorSize.height.rounded(.down)
            var width = min((needed.width + 2 * margin).rounded(.up), sensorW)
            var height = min((needed.height + 2 * margin).rounded(.up), sensorH)
            if width == avoiding.width, height == avoiding.height {
                if width < sensorW { width += 1 } else if width > 1 { width -= 1 }
            }
            func place(_ start: CGFloat, _ size: CGFloat, _ extent: CGFloat) -> CGFloat {
                min(max(start.rounded(.down), 0), max(extent - size, 0))
            }
            return CGRect(x: place(needed.minX - margin, width, sensorW),
                          y: place(needed.minY - margin, height, sensorH),
                          width: width, height: height)
        }
    }

    // MARK: - Pixel sampling

    /// Above this zoom the full-resolution tile is drawn with
    /// nearest-neighbour sampling, so each sensor pixel is a crisp square
    /// and demosaic, sharpening and noise reduction artefacts show exactly
    /// as they are. At or below it bilinear filtering keeps things smooth.
    public static let squarePixelsAbove: CGFloat = 2

    /// Whether a full-resolution layer drawn at `zoom` (drawable pixels per
    /// sensor pixel) samples nearest-neighbour.
    public static func samplesNearest(zoom: CGFloat) -> Bool {
        zoom > squarePixelsAbove + 1e-3
    }
}
