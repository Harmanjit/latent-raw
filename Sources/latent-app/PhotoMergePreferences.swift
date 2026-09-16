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

/// The panorama merge options Latent remembers between merges, as it
/// remembers the HDR dialog's: Projection, Auto Crop and Auto Settings, as
/// the dialog was last left.
///
/// Agreeing to a smaller panorama is never remembered: it belongs to one
/// sweep on one Mac, and the dialog must ask every time.
struct PanoramaMergePreferences {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static let projectionKey = "PhotoMerge.Panorama.projection"
    static let autoCropKey = "PhotoMerge.Panorama.autoCrop"
    static let autoSettingsKey = "PhotoMerge.Panorama.autoSettings"

    /// Automatic unless another was chosen, as in Lightroom.
    var projection: PanoramaProjection {
        get {
            defaults.string(forKey: Self.projectionKey).flatMap(PanoramaProjection.init(rawValue:)) ?? .automatic
        }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Self.projectionKey) }
    }

    /// On unless it was turned off, as in Lightroom.
    var autoCrop: Bool {
        get { defaults.object(forKey: Self.autoCropKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.autoCropKey) }
    }

    /// Off unless it was turned on, as in Lightroom.
    var autoSettings: Bool {
        get { defaults.object(forKey: Self.autoSettingsKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.autoSettingsKey) }
    }

    var options: PanoramaMergeOptions {
        PanoramaMergeOptions(projection: projection, autoCrop: autoCrop, autoSettings: autoSettings)
    }
}
