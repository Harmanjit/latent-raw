import Foundation
import ColorKit

/// Which profile an edit renders with, as stored in its edit stack
/// (`EditStack.Modules.profile`). Absent means Latent Standard, so every
/// edit from before profiles keeps its exact rendering.
public struct ProfileChoice: Codable, Equatable, Sendable {
    /// A built-in id ("latent:vivid") or an imported DCP's ("dcp:<file name>").
    public var id: String
    /// The name shown in the picker, kept so an edit whose DCP isn't on
    /// this Mac can still say which profile it wants.
    public var name: String
    /// Creative profiles' Amount, 0 to the profile's maximum; nil is 100%.
    public var amount: Float?
    /// For a DCP with a tone curve: whether to apply it. nil is off.
    public var toneCurve: Bool?

    public init(id: String, name: String, amount: Float? = nil, toneCurve: Bool? = nil) {
        self.id = id
        self.name = name
        self.amount = amount
        self.toneCurve = toneCurve
    }

    public static let dcpPrefix = "dcp:"

    public var isDCP: Bool { id.hasPrefix(Self.dcpPrefix) }
    public var builtIn: BuiltInProfile? { BuiltInProfile.named(id) }

    /// The Amount in effect, clamped to what the profile allows.
    public var effectiveAmount: Float {
        let maximum = builtIn?.maximumAmount ?? 1
        guard builtIn?.hasAmount == true, let amount, amount.isFinite else { return 1 }
        return min(max(amount, 0), maximum)
    }

    /// A choice as it should be stored: nil for Standard (or an empty
    /// id), and an amount only where one means something.
    public var sanitized: ProfileChoice? {
        guard !id.isEmpty, id != BuiltInProfile.standardID else { return nil }
        var c = self
        if c.name.isEmpty { c.name = builtIn?.name ?? "Profile" }
        if builtIn?.hasAmount == true {
            c.amount = (amount ?? 1).isFinite ? min(max(amount ?? 1, 0), builtIn?.maximumAmount ?? 1) : 1
            if c.amount == 1 { c.amount = nil }
        } else {
            c.amount = nil
        }
        if !isDCP || c.toneCurve == false { c.toneCurve = nil }
        return c
    }

    public static func builtIn(_ profile: BuiltInProfile) -> ProfileChoice? {
        ProfileChoice(id: profile.id, name: profile.name).sanitized
    }
}

/// The DCP files the user has imported, kept in Application Support so
/// they outlive the folder they came from. Nothing is bundled and nothing
/// is ever downloaded; Import Camera Profile… is the only way in.
///
/// Thread-safe: renders on any thread look profiles up by id.
public final class CameraProfileLibrary: @unchecked Sendable {
    public static let shared = CameraProfileLibrary(directory: defaultDirectory)

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("latent/profiles", isDirectory: true)
    }

    public let directory: URL
    private let lock = NSLock()
    private var parsed: [String: DCPProfile] = [:]
    private var listing: [Entry]?

    public init(directory: URL) {
        self.directory = directory
    }

    /// One imported profile, as the picker lists it.
    public struct Entry: Identifiable, Equatable, Sendable {
        /// "dcp:<file name>", stored in edits.
        public var id: String
        public var name: String
        public var uniqueCameraModel: String?
        public var fileName: String
        public var hasToneCurve: Bool
    }

    /// Posted on the main queue after an import, so open pickers refresh.
    public static let didChangeNotification = Notification.Name("CameraProfileLibraryDidChange")

    /// Every readable profile in the folder, by name. Files that don't
    /// parse are left out (and left alone).
    public func entries() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        if let listing { return listing }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var result: [Entry] = []
        for url in files where url.pathExtension.lowercased() == "dcp" {
            let id = Self.dcpPrefix + url.lastPathComponent
            guard let profile = parsed[id] ?? (try? DCPProfile(contentsOf: url)) else { continue }
            parsed[id] = profile
            result.append(Self.entry(id: id, fileName: url.lastPathComponent, profile: profile))
        }
        result.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        listing = result
        return result
    }

    static let dcpPrefix = ProfileChoice.dcpPrefix

    static func entry(id: String, fileName: String, profile: DCPProfile) -> Entry {
        Entry(id: id, name: profile.name ?? (fileName as NSString).deletingPathExtension,
              uniqueCameraModel: profile.uniqueCameraModel, fileName: fileName,
              hasToneCurve: profile.hasToneCurve)
    }

    /// The parsed profile for an id, or nil when it isn't here (an edit
    /// made on another Mac) or no longer parses.
    public func profile(id: String) -> DCPProfile? {
        guard id.hasPrefix(Self.dcpPrefix) else { return nil }
        let fileName = String(id.dropFirst(Self.dcpPrefix.count))
        // A stored id is only ever a bare file name in this folder.
        guard !fileName.isEmpty, !fileName.contains("/"), fileName != "..", fileName != "." else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let p = parsed[id] { return p }
        guard let p = try? DCPProfile(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
        parsed[id] = p
        return p
    }

    public func entry(id: String) -> Entry? {
        entries().first { $0.id == id }
    }

    /// Copies a .dcp into the library after checking it parses. A file
    /// with the same bytes as one already there returns that one; a
    /// different file with a taken name gets a numbered name.
    @discardableResult
    public func importProfile(from url: URL) throws -> Entry {
        let data = try Data(contentsOf: url)
        let profile = try DCPProfile(data: data)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let base = Self.safeBaseName(url.deletingPathExtension().lastPathComponent)
        var attempt = 1
        while true {
            let fileName = attempt == 1 ? "\(base).dcp" : "\(base) \(attempt).dcp"
            let destination = directory.appendingPathComponent(fileName)
            if fm.fileExists(atPath: destination.path) {
                if (try? Data(contentsOf: destination)) == data {
                    return Self.entry(id: Self.dcpPrefix + fileName, fileName: fileName, profile: profile)
                }
                attempt += 1
                continue
            }
            try data.write(to: destination, options: .withoutOverwriting)
            let id = Self.dcpPrefix + fileName
            lock.lock()
            parsed[id] = profile
            listing = nil
            lock.unlock()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
            }
            return Self.entry(id: id, fileName: fileName, profile: profile)
        }
    }

    static func safeBaseName(_ name: String) -> String {
        let cleaned = name.map { c -> Character in
            c == "/" || c == ":" || c == "\\" ? "-" : c
        }
        let trimmed = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return trimmed.isEmpty ? "Profile" : String(trimmed.prefix(120))
    }

    /// Whether a profile made for `uniqueCameraModel` is meant for this
    /// camera. Adobe names cameras "Make Model" ("Nikon D750"); LibRaw
    /// splits them. Compared without case, spaces or punctuation.
    public static func matches(uniqueCameraModel: String?, cameraMake: String, cameraModel: String) -> Bool {
        guard let unique = uniqueCameraModel else { return false }
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let u = squash(unique), make = squash(cameraMake), model = squash(cameraModel)
        guard !u.isEmpty, !model.isEmpty else { return false }
        return u == make + model || u == model || (model.hasPrefix(make) && u == model)
            || (make.count >= 3 && u.hasPrefix(String(make.prefix(3))) && u.hasSuffix(model) && model.count >= 3)
    }
}
