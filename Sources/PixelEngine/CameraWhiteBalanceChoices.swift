import Foundation
import ColorKit
import RawCore

/// One of the camera's own white balance presets, as a temperature and
/// tint the White Balance menu can set (its "Camera presets" section).
/// The camera's multipliers go through the same solver that turns the
/// as-shot multipliers into the sliders' values, so choosing the camera's
/// Daylight here looks as the camera's Daylight would have.
public struct CameraWhiteBalanceChoice: Identifiable, Equatable, Sendable {
    /// Unique within one photo's list.
    public let id: String
    public let title: String
    public let balance: ColorKit.WhiteBalance

    public init(id: String, title: String, balance: ColorKit.WhiteBalance) {
        self.id = id
        self.title = title
        self.balance = balance
    }

    /// The choices for a file's presets, light sources first in the
    /// camera's order, then its Kelvin entries from warm to cool. Empty
    /// without a camera profile (temperature and tint mean nothing then)
    /// or without presets, so the menu keeps only its generic ones.
    static func choices(for presets: [CameraWhiteBalancePreset],
                        profile: ColorKit.CameraColorProfile?) -> [CameraWhiteBalanceChoice] {
        guard let profile, !presets.isEmpty else { return [] }
        let ordered = presets.filter { $0.illuminant != CameraWhiteBalancePreset.kelvinCode }
            + presets.filter { $0.illuminant == CameraWhiteBalancePreset.kelvinCode }.sorted { $0.kelvin < $1.kelvin }
        var seen = Set<String>()
        var out: [CameraWhiteBalanceChoice] = []
        for preset in ordered where preset.multipliers.count == 4 {
            let m = preset.multipliers
            // A second green of 0 means the camera recorded only one.
            let mul = ColorKit.normalizedWhiteBalance((m[0], m[1], m[2], m[3] > 0 ? m[3] : m[1]))
            let balance = profile.whiteBalance(fromMultipliers: mul)
            guard balance.temperature.isFinite, balance.tint.isFinite else { continue }
            var id = preset.title
            var n = 2
            while seen.contains(id) { id = "\(preset.title) \(n)"; n += 1 }
            seen.insert(id)
            out.append(CameraWhiteBalanceChoice(id: id, title: id, balance: balance))
        }
        return out
    }
}
