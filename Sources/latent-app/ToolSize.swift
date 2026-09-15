import Foundation

/// How [ and ] change a brush or spot size.
enum ToolSizeStep {
    /// Each press scales the size by this, so a small brush changes by a
    /// few pixels and a large one by tens, and a handful of presses gets
    /// anywhere in the range.
    static let factor: Float = 1.25

    /// Match the Size sliders: the mask brush's (a fraction of the short
    /// side) in LocalAdjustmentsPanel and the spot tool's (in sensor pixels)
    /// under Spot Removal, so a key never takes a size past its slider.
    static let brushRadius: ClosedRange<Float> = 0.005...0.2
    static let healRadiusPixels: ClosedRange<Float> = 4...600
    static let redEyeRadiusPixels: ClosedRange<Float> = 2...400

    static func stepped(_ value: Float, by steps: Int, within range: ClosedRange<Float>) -> Float {
        let scaled = value * pow(factor, Float(steps))
        return min(max(scaled, range.lowerBound), range.upperBound)
    }
}

extension EditorModel {
    /// The spot tool, or the mask brush (painting or erasing), is armed.
    var toolSizeAdjustable: Bool {
        healToolActive || redEyeToolActive || (maskToolActive && (maskTool == .brush || maskTool == .erase))
    }

    /// Steps the armed tool's size: the spot tool's next patch and the
    /// selected patch, or the mask brush. Returns false with neither armed.
    @discardableResult
    func stepToolSize(by steps: Int) -> Bool {
        if healToolActive {
            activeHealRadiusPixels = ToolSizeStep.stepped(activeHealRadiusPixels, by: steps,
                                                          within: ToolSizeStep.healRadiusPixels)
            return true
        }
        if redEyeToolActive {
            activeRedEyeRadiusPixels = ToolSizeStep.stepped(activeRedEyeRadiusPixels, by: steps,
                                                            within: ToolSizeStep.redEyeRadiusPixels)
            return true
        }
        guard toolSizeAdjustable else { return false }
        brushRadius = ToolSizeStep.stepped(brushRadius, by: steps, within: ToolSizeStep.brushRadius)
        return true
    }
}
