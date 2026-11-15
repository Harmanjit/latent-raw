import Foundation

/// What to open from the command line (`swift run latent-app ~/Photos/Shoot`
/// or `open Latent.app --args file.NEF`). Lives here rather than in the app
/// target because the app has no test target and this is easy to get wrong.
public enum LaunchArguments {
    /// The arguments, without the program name, that name an existing file
    /// or folder, in order. An argument starting with "-" is a defaults
    /// override that takes the next argument as its value
    /// (`-AppleLanguages (en)`, which Xcode and `open --args` users pass),
    /// so both are skipped; otherwise "(en)" would be taken for a path.
    public static func paths(from arguments: [String]) -> [String] {
        var remaining = arguments[...]
        var paths: [String] = []
        while let argument = remaining.popFirst() {
            if argument.hasPrefix("-") {
                _ = remaining.popFirst()
            } else if FileManager.default.fileExists(atPath: argument) {
                paths.append(argument)
            }
        }
        return paths
    }
}

extension LaunchArguments {
    /// What a launch, or an open request from Finder, the Dock or the
    /// command line, asks the window to show.
    public enum Target: Equatable, Sendable {
        /// A folder, opened as the catalog.
        case folder(URL)
        /// A single image, opened in Develop.
        case file(URL)

        public var url: URL {
            switch self {
            case .folder(let url), .file(let url): url
            }
        }
    }

    /// The first of `paths` that exists, as a folder or a file. Only one
    /// item is opened: the window shows one catalog and one image.
    public static func target(forPaths paths: [String]) -> Target? {
        for path in paths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            let url = URL(fileURLWithPath: path, isDirectory: isDirectory.boolValue).standardizedFileURL
            return isDirectory.boolValue ? .folder(url) : .file(url)
        }
        return nil
    }

    /// The same for the URLs of an open-documents event
    /// (`application(_:open:)`). Anything but a file URL is ignored.
    public static func target(for urls: [URL]) -> Target? {
        target(forPaths: urls.filter(\.isFileURL).map(\.path))
    }

    /// What to open as the window first appears: the item of an
    /// open-documents event that arrived during launch (Finder's Open
    /// With, a drop on the Dock icon, or AppKit's own reading of a file
    /// named on the command line), else the first path among `arguments`.
    public static func launchTarget(pendingEvent: Target?, arguments: [String]) -> Target? {
        pendingEvent ?? target(forPaths: paths(from: arguments))
    }
}
