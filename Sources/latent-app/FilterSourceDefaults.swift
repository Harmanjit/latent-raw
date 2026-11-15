import Foundation
import Catalog

/// Keeps "Remember Filter per Source" and the filters it remembered
/// between launches (see `FilterSourceMemory`). App-wide, in UserDefaults,
/// like the sort: nothing is written into the catalogs.
@MainActor
enum FilterSourceDefaults {
    static let enabledKey = "latent.rememberFilterPerSource"
    static let memoryKey = "latent.filterPerSource"

    /// Restores the saved option and filters into `library` and saves every
    /// change after.
    static func attached(to library: Library, defaults: UserDefaults = .standard) -> Library {
        library.restoreFilterMemory(enabled: defaults.bool(forKey: enabledKey),
                                    memory: FilterSourceMemory.decode(defaults.data(forKey: memoryKey)))
        library.filterMemoryDidChange = { enabled, memory in
            defaults.set(enabled, forKey: enabledKey)
            if let data = memory.encoded() { defaults.set(data, forKey: memoryKey) }
        }
        return library
    }
}
