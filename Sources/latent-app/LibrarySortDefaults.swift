import Foundation
import Catalog

/// Keeps the grid's sort, and each key's direction, between launches
/// (see `LibrarySortMemory`). App-wide rather than per catalog, as Finder
/// keeps its view options: a folder opens sorted the way the last one was.
@MainActor
enum LibrarySortDefaults {
    static let key = "latent.librarySort"

    /// Restores the saved sort into `library` and saves every change after.
    static func attached(to library: Library, defaults: UserDefaults = .standard) -> Library {
        library.restoreSort(defaults.dictionary(forKey: key))
        library.sortDidChange = { sort, memory in
            defaults.set(memory.stored(showing: sort), forKey: key)
        }
        return library
    }
}
