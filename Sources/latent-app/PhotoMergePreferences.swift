import Foundation
import MergeKit

/// The HDR merge options Latent remembers between merges, as Lightroom
/// remembers its merge options: Auto Align, Deghost and Auto Settings, as
/// the dialog was last left. HDR Merge Without Dialog merges with them.
///
/// The reference photo is not remembered: it belongs to one bracket.
struct HDRMergePreferences {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let autoAlignKey = "PhotoMerge.HDR.autoAlign"
    static let deghostKey = "PhotoMerge.HDR.deghost"
    static let autoSettingsKey = "PhotoMerge.HDR.autoSettings"

    /// On unless it was turned off, as in Lightroom.
    var autoAlign: Bool {
        get { defaults.object(forKey: Self.autoAlignKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.autoAlignKey) }
    }

    /// None unless a level was chosen, as in Lightroom.
    var deghost: DeghostAmount {
        get { defaults.string(forKey: Self.deghostKey).flatMap(DeghostAmount.init(rawValue:)) ?? DeghostAmount.none }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.deghostKey) }
    }

    /// Off unless it was turned on, as in Lightroom.
    var autoSettings: Bool {
        get { defaults.object(forKey: Self.autoSettingsKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.autoSettingsKey) }
    }

    /// The engine's options, with the reference chosen automatically.
    var options: HDRMergeOptions {
        HDRMergeOptions(deghost: deghost, autoAlign: autoAlign)
    }
}
