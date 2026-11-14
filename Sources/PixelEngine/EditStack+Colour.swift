import Foundation

/// The edit-stack side of `ColourControls`: five modules, each written only
/// when it changes something, and read back with anything a hand-edited
/// file could break brought into range.
extension EditStack {
    public struct Saturation: Codable, Equatable, Sendable { public var amount: Float }
    /// Gamut Compression's and Highlight Purity's modules, 0…1.
    public struct ColourAmount: Codable, Equatable, Sendable { public var amount: Float }

    mutating func setColourControls(_ c: ColourControls) {
        modules.saturation = c.saturation == 0 ? nil : Saturation(amount: c.saturation)
        modules.blackwhite = c.blackAndWhite.isNeutral ? nil : c.blackAndWhite
        modules.colorgrading = c.grading.isNeutral ? nil : c.grading
        modules.calibration = c.calibration.isNeutral ? nil : c.calibration
        modules.pointcolor = c.pointColours.isEmpty ? nil : c.pointColours
        modules.adaptation = c.adaptation.isNeutral ? nil : c.adaptation
        modules.channelmixer = c.channelMixer.isNeutral ? nil : c.channelMixer
        modules.gamutcompression = c.gamutCompression == 0 ? nil : ColourAmount(amount: c.gamutCompression)
        modules.purity = c.purity == 0 ? nil : ColourAmount(amount: c.purity)
    }

    var colourControls: ColourControls {
        let s = modules.saturation?.amount ?? 0
        var c = ColourControls(
            saturation: s.isFinite ? min(max(s, -1), 1) : 0,
            blackAndWhite: (modules.blackwhite ?? .off).sanitized,
            grading: (modules.colorgrading ?? .neutral).sanitized,
            calibration: (modules.calibration ?? .neutral).sanitized,
            pointColours: (modules.pointcolor ?? []).prefix(PointColour.maximumCount).map(\.sanitized))
        c.adaptation = (modules.adaptation ?? .neutral).sanitized
        c.channelMixer = (modules.channelmixer ?? .identity).sanitized
        func unit(_ v: Float?) -> Float { v.map { $0.isFinite ? min(max($0, 0), 1) : 0 } ?? 0 }
        c.gamutCompression = unit(modules.gamutcompression?.amount)
        c.purity = unit(modules.purity?.amount)
        return c
    }
}

extension EditHistory {
    /// The colour modules by their panel names, for the History list.
    static func colourChanges(from a: EditStack.Modules, to b: EditStack.Modules) -> [String] {
        var names: [String] = []
        if a.saturation != b.saturation { names.append("Saturation") }
        if a.blackwhite != b.blackwhite {
            names.append((a.blackwhite?.enabled ?? false) != (b.blackwhite?.enabled ?? false) ? "Treatment" : "B&W Mix")
        }
        if a.colorgrading != b.colorgrading { names.append("Colour Grading") }
        if a.calibration != b.calibration { names.append("Calibration") }
        if a.pointcolor != b.pointcolor { names.append("Point Colour") }
        if a.adaptation != b.adaptation { names.append("Adaptation") }
        if a.channelmixer != b.channelmixer { names.append("Channel Mixer") }
        if a.gamutcompression != b.gamutcompression { names.append("Gamut Compression") }
        if a.purity != b.purity { names.append("Highlight Purity") }
        return names
    }
}
