import Foundation

extension EditStack {
    /// Why a stored edit can't be flipped outside Develop.
    public enum FlipError: Error, Equatable {
        /// Its crop or masks measure the whole sensor readout (a stack
        /// from before the active area); only opening the image knows
        /// where that readout's centre falls on the picture.
        case legacyGeometry
    }

    /// This edit flipped left-to-right (`horizontal`) or top-to-bottom,
    /// exactly as Develop › Transform › Flip does it on the open image
    /// (`EditorModel.flip`): the Transform flip and the sliders it turns
    /// round, the crop and the masks mirrored about the sensor's centre.
    /// For Photo › Flip Horizontal and Flip Vertical on a selection in the
    /// grid, which change stored edits without opening them.
    ///
    /// Flipping twice gives back the same edit; a flip that leaves the
    /// Transform at its defaults drops the module, so an edit flipped and
    /// flipped back encodes as it did.
    public func flipped(horizontal: Bool) throws -> EditStack {
        var out = self
        let hasMirroredGeometry = modules.crop != nil || modules.locals != nil
        if hasMirroredGeometry, frame != Self.activeAreaFrame {
            throw FlipError.legacyGeometry
        }
        var transform = modules.perspective?.correction ?? .none
        transform.flip(horizontal: horizontal)
        // Negating a zero gives -0, which would encode as "-0": adding 0
        // makes it plain 0 again.
        transform.vertical += 0; transform.horizontal += 0; transform.rotate += 0
        transform.offsetX += 0; transform.offsetY += 0
        out.modules.perspective = transform.isNeutral ? nil : Perspective(transform: transform)
        if let c = modules.crop {
            var crop = c
            if horizontal { crop.cx = 1 - c.cx } else { crop.cy = 1 - c.cy }
            crop.angle = -c.angle + 0
            out.modules.crop = crop
        }
        out.modules.locals = modules.locals?.map { local in
            var mirrored = local
            mirrored.shape = local.shape.mirrored(horizontal: horizontal)
            return mirrored
        }
        return out
    }
}
