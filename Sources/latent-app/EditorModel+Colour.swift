import SwiftUI
import PixelEngine

/// Black & White and Point Colour: the parts of the colour controls that
/// read the image (ColourControls.swift has the rest).
extension EditorModel {
    // MARK: - Treatment and B&W Mix

    var isBlackAndWhite: Bool { parameters.colour.blackAndWhite.enabled }

    /// Switches between Color and Black & White. The first switch to
    /// Black & White on an image whose mix was never set also sets the mix
    /// with Auto, as Lightroom does; both land in one history step.
    func setBlackAndWhite(_ on: Bool) {
        guard hasImage, on != isBlackAndWhite else { return }
        var next = parameters
        next.colour.blackAndWhite.enabled = on
        if on, next.colour.blackAndWhite.mixIsNeutral, let mix = autoBlackAndWhiteMix() {
            next.colour.blackAndWhite.mix = mix
        }
        parameters = next
    }

    func toggleBlackAndWhite() { setBlackAndWhite(!isBlackAndWhite) }

    /// The B&W Mix panel's Auto button.
    func applyAutoBlackAndWhiteMix() {
        guard let mix = autoBlackAndWhiteMix() else { return }
        parameters.colour.blackAndWhite.mix = mix
    }

    private func autoBlackAndWhiteMix() -> [Float]? {
        guard let session, let pipeline, let gpuContext else { return nil }
        do {
            let image = try GradingImage.render(session: session, pipeline: pipeline, gpu: gpuContext,
                                                parameters: parameters, stage: .beforeColourMix)
            return BlackAndWhite.autoMix(for: image)
        } catch {
            status = "Auto mix failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: - Point Colour picker

    /// Arms the picker: the next click on the image adds a swatch of the
    /// colour under it. Click-only, so it disarms itself after one pick.
    func beginPointColourPick() {
        guard hasImage else { return }
        guard parameters.colour.pointColours.count < PointColour.maximumCount else {
            status = "At most \(PointColour.maximumCount) point colours per image"
            return
        }
        pointColourPicking = true
    }

    /// The press of a pick: reads the colour as Point Colour sees it (after
    /// the curves and HSL, before the other colour controls) and adds it.
    func pointColourPicked(at screen: CGPoint) {
        guard let session, let pipeline, let gpuContext, hasImage else { return }
        let point = sensorNormalized(screen)
        do {
            let image = try GradingImage.render(session: session, pipeline: pipeline, gpu: gpuContext,
                                                parameters: parameters, stage: .beforePointColour)
            guard let rgb = image.averageColour(at: point) else {
                status = "Click on the photo to pick a colour"
                return
            }
            guard parameters.colour.pointColours.count < PointColour.maximumCount else { return }
            parameters.colour.pointColours.append(PointColour(picked: rgb))
            selectedPointColour = parameters.colour.pointColours.count - 1
        } catch {
            status = "Picking the colour failed: \(error.localizedDescription)"
        }
    }

    func deletePointColour(at index: Int) {
        guard parameters.colour.pointColours.indices.contains(index) else { return }
        parameters.colour.pointColours.remove(at: index)
        let count = parameters.colour.pointColours.count
        selectedPointColour = count == 0 ? nil : min(index, count - 1)
    }
}
