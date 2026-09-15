import Foundation
import PixelEngine

extension EditorModel {
    // MARK: - Crop and straighten

    /// The geometry of the stored crop (what export uses).
    private var cropFrame: CropFrame {
        CropFrame(sensorSize: sensorSize, crop: parameters.crop, rotation: rotation)
    }

    /// The geometry the viewport shows: the crop, or with the tool open,
    /// the whole sensor at the crop's angle.
    var frame: CropFrame { cropToolActive ? cropFrame.toolFrame : cropFrame }

    /// The crop rectangle on the tool canvas, in canvas pixels. Setting it
    /// is what the overlay's handles do.
    var cropCanvasRect: CGRect {
        get { cropFrame.toolCanvasRect }
        set {
            guard hasImage else { return }
            straightenBase = nil
            parameters.crop = cropFrame.cropForToolCanvasRect(newValue).constrained(sensorSize: sensorSize)
        }
    }

    /// Bounds the crop rectangle may occupy on the tool canvas. Exact at
    /// 0°; at other angles the sensor is a tilted rectangle inside this
    /// box and `constrained` shrinks the crop to stay on it.
    var cropCanvasBounds: CGRect { CGRect(origin: .zero, size: frame.canvasSize) }

    func setStraighten(_ degrees: Float) {
        guard hasImage else { return }
        var base = straightenBase ?? parameters.crop
        base.angle = max(-45, min(45, degrees))
        straightenBase = base
        parameters.crop = base.constrained(sensorSize: sensorSize)
    }

    /// Locks the crop to `ratio` (width:height as displayed, so a
    /// portrait-oriented image's "3:2" is tall), or frees it with nil.
    func setCropAspect(displayRatio ratio: Float?) {
        guard hasImage else { return }
        straightenBase = nil
        guard let ratio else { parameters.crop.aspect = nil; return }
        let sensorRatio = rotation.swapsAxes ? 1 / ratio : ratio
        parameters.crop = parameters.crop.withAspect(sensorRatio, sensorSize: sensorSize)
    }

    /// The lock as displayed, or nil when free.
    var cropAspectDisplayRatio: Float? {
        guard let a = parameters.crop.aspect else { return nil }
        return rotation.swapsAxes ? 1 / a : a
    }

    /// The image's own ratio as displayed, for the "Original" option.
    var originalDisplayRatio: Float {
        let s = rotation.imageSize(forSensorSize: sensorSize)
        return s.height > 0 ? Float(s.width / s.height) : 1
    }

    /// Output size in pixels after the crop, as displayed.
    var croppedPixelSize: CGSize { cropFrame.canvasSize }

    func resetCrop() {
        guard hasImage else { return }
        straightenBase = nil
        parameters.crop = .none
        parameters.perspective = .none
    }

    /// The canvas changed size or shape (crop, tool, rotation): re-fit if
    /// fitted, else keep the view clamped to the new canvas.
    func canvasDidChange() {
        guard hasImage, drawableSize.width > 0 else { return }
        if fitMode {
            viewport = .fit(imageSize: imageSize, drawableSize: drawableSize)
        } else {
            viewport = viewport.clamped(imageSize: imageSize, drawableSize: drawableSize)
        }
    }
}
