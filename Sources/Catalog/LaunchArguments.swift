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
