import Combine
import Foundation
import Catalog

/// Carries Settings › Library › "Show JPEGs of RAW+JPEG pairs as separate
/// photos" into the Library, now and whenever it changes.
@MainActor
enum PairedJPEGDefaults {
    static let key = "latent.showPairedJPEGsSeparately"
    private static var subscription: AnyCancellable?

    static func attached(to library: Library, preferences: AppPreferences = .shared) -> Library {
        library.showsPairedCompanions = preferences.showPairedJPEGsSeparately
        subscription = preferences.$showPairedJPEGsSeparately
            .removeDuplicates()
            .sink { [weak library] value in library?.showsPairedCompanions = value }
        return library
    }
}
