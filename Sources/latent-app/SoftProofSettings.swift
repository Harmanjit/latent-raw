import AppKit
import ColorKit
import PixelEngine

/// The soft proof's view settings kept between launches beside its options
/// (`SoftProofOptionsStore`): the colours its gamut warnings are painted
/// in, and what Before shows while proofing.
struct SoftProofSettingsStore {
    let defaults: UserDefaults
    static let coloursKey = "latent.softProofWarningColours"
    static let beforeKey = "latent.softProofBeforeShowsUnproofed"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var warningColours: GamutWarningColours {
        get {
            guard let data = defaults.data(forKey: Self.coloursKey),
                  let colours = try? JSONDecoder().decode(GamutWarningColours.self, from: data) else { return .standard }
            return colours
        }
        nonmutating set {
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: Self.coloursKey) }
        }
    }

    /// While proofing, Before (\) shows the edit without the proof, as
    /// Lightroom's Before/After does in Soft Proofing, rather than the
    /// photo before editing. On unless turned off.
    var beforeShowsUnproofed: Bool {
        get { defaults.object(forKey: Self.beforeKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.beforeKey) }
    }
}

/// The last proof target chosen, remembered across launches. A profile is
/// kept as a security-scoped bookmark: under the App Sandbox a path alone
/// would name a file the app may no longer read. Soft Proofing itself
/// always starts off; only what it proofs against is remembered.
struct SoftProofTargetStore {
    let defaults: UserDefaults
    static let kindKey = "latent.softProofTarget"
    static let bookmarkKey = "latent.softProofTargetBookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func save(_ target: SoftProofTarget) {
        switch target {
        case .sRGB:
            defaults.set("sRGB", forKey: Self.kindKey)
            defaults.removeObject(forKey: Self.bookmarkKey)
        case .displayP3:
            defaults.set("displayP3", forKey: Self.kindKey)
            defaults.removeObject(forKey: Self.bookmarkKey)
        case .icc(let url):
            guard let data = BookmarkStore.bookmark(for: url) else { return }
            defaults.set("icc", forKey: Self.kindKey)
            defaults.set(data, forKey: Self.bookmarkKey)
        case .profile:
            // A profile in memory (the screen's) is never chosen as a
            // target, and couldn't be found again if it were.
            break
        }
    }

    /// The target to start with: the last one chosen, or sRGB when none
    /// was or its profile can't be read any more. Resolving never mounts
    /// a volume or shows a dialog: a profile on a disk that's away just
    /// isn't restored.
    func restored() -> SoftProofTarget {
        switch defaults.string(forKey: Self.kindKey) {
        case "displayP3": return .displayP3
        case "icc":
            guard let data = defaults.data(forKey: Self.bookmarkKey),
                  let (url, _) = BookmarkStore.resolveQuietly(data) else { return .sRGB }
            _ = url.startAccessingSecurityScopedResource()
            return ICCProfile(url: url) != nil ? .icc(url) : .sRGB
        default: return .sRGB
        }
    }
}

/// The ICC profiles Soft Proof offers besides sRGB and Display P3: those
/// the user added (from ~/Library/ColorSync/Profiles, a printer maker's
/// download, anywhere), remembered as security-scoped bookmarks, and those
/// installed in the Mac's shared ColorSync folders, which every app can
/// read. The sandbox keeps the app out of ~/Library/ColorSync/Profiles
/// until a profile there has been chosen in an open panel, so those are
/// added rather than listed.
@MainActor
final class ProofProfileLibrary: ObservableObject {
    static let shared = ProofProfileLibrary()

    struct Profile: Identifiable, Hashable {
        let url: URL
        var name: String { url.deletingPathExtension().lastPathComponent }
        var id: String { url.standardizedFileURL.path }
    }

    /// Profiles the user added, in the order added.
    @Published private(set) var added: [Profile] = []
    /// Profiles found in /Library and /System, by name (`loadInstalled`).
    @Published private(set) var installed: [Profile] = []

    private let defaults: UserDefaults
    private var bookmarks: [Data] = []
    private var installedLoaded = false
    static let key = "latent.proofProfileBookmarks"

    /// Resolving is quiet (no mounting, no dialogs), so a profile on a
    /// disk that's away is simply left out of the menu until the next
    /// launch finds it; its bookmark is kept.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bookmarks = defaults.array(forKey: Self.key) as? [Data] ?? []
        for data in bookmarks {
            guard let (url, _) = BookmarkStore.resolveQuietly(data) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            let profile = Profile(url: url)
            if !added.contains(profile) { added.append(profile) }
        }
    }

    /// Adds a profile chosen in an open panel (which is what grants access
    /// to it). Returns false for a file that isn't an ICC profile ColorSync
    /// can read, or that no bookmark can be made for.
    @discardableResult
    func add(_ url: URL) -> Bool {
        guard ICCProfile(url: url) != nil else { return false }
        let profile = Profile(url: url)
        if added.contains(profile) || installed.contains(profile) { return true }
        guard let data = BookmarkStore.bookmark(for: url) else { return false }
        _ = url.startAccessingSecurityScopedResource()
        added.append(profile)
        bookmarks.append(data)
        defaults.set(bookmarks, forKey: Self.key)
        return true
    }

    /// Forgets an added profile. Its access stays open until quit: the
    /// proof on screen, or a print, may be using it.
    func remove(_ profile: Profile) {
        guard let index = added.firstIndex(of: profile) else { return }
        added.remove(at: index)
        // Bookmarks that didn't resolve aren't in `added`, so the one to
        // drop is found by the file it names.
        bookmarks.removeAll { data in
            BookmarkStore.resolveQuietly(data).map { Profile(url: $0.url) == profile } ?? false
        }
        defaults.set(bookmarks, forKey: Self.key)
    }

    /// Lists the installed profiles once, off the main thread.
    func loadInstalled() async {
        guard !installedLoaded else { return }
        installedLoaded = true
        installed = await Task.detached(priority: .utility) { Self.installedProfiles() }.value
    }

    /// The profiles in the shared ColorSync folders (and one level down,
    /// where printer drivers install theirs) that make sense to proof
    /// against: RGB, CMYK and grey output profiles. sRGB and Display P3
    /// are already in the menu.
    nonisolated static func installedProfiles(in folders: [URL] = ExportColorProfile.profileFolders) -> [Profile] {
        let fm = FileManager.default
        var found: [String: Profile] = [:]
        for folder in folders {
            var files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sub in files where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                files += (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
            }
            for url in files where ["icc", "icm"].contains(url.pathExtension.lowercased()) {
                let profile = Profile(url: url)
                guard found[profile.name] == nil, isProofable(url) else { continue }
                found[profile.name] = profile
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    nonisolated static func isProofable(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 64 << 20,
              let space = CGColorSpace(iccData: data as CFData),
              [.rgb, .cmyk, .monochrome].contains(space.model) else { return false }
        let name = url.deletingPathExtension().lastPathComponent
        return !["sRGB", "Display P3"].contains { name.localizedCaseInsensitiveContains($0) }
    }

    /// The real ~/Library/ColorSync/Profiles, where an open panel starts.
    /// Under the sandbox the home directory the app sees is its container,
    /// so it is read from the user database instead.
    nonisolated static var userProfilesFolder: URL {
        let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Library/ColorSync/Profiles", isDirectory: true)
    }
}

extension EditorModel {
    /// Chooses what Soft Proof proofs against from the panel or menu, and
    /// remembers it for the next launch.
    func selectProofTarget(_ target: SoftProofTarget) {
        proofTarget = target
        SoftProofTargetStore().save(target)
    }

    /// While proofing with Before showing, whether Before is the edit
    /// without the proof (`SoftProofSettingsStore.beforeShowsUnproofed`)
    /// rather than the photo before editing.
    var showsUnproofedBefore: Bool { showingBefore && proofLUT != nil && proofBeforeShowsUnproofed }

    /// The screen the editor is on and the profile macOS uses for it, as
    /// the Soft Proof panel shows them.
    static func monitorProfileDescription(screen: NSScreen? = NSApp?.keyWindow?.screen ?? NSScreen.main) -> String? {
        guard let screen else { return nil }
        let profile = screen.colorSpace?.localizedName ?? "Display P3"
        return "\(screen.localizedName) · \(profile)"
    }
}
